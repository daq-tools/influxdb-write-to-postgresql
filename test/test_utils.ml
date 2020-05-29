open Influxdb_write_to_postgresql

type host_ip_port = {
  host_ip : string;
  host_port : int;
}

module PortMap = Map.Make(struct type t = string let compare = compare end)
type ports = host_ip_port PortMap.t

type container_info = {
  ci_id: string;
  ci_ports: ports;
}

type json = Yojson.Basic.t

module JsonWalker =
struct
  type error =
    | NoSuchNode
    | InvalidNodeType

  exception Error of error

  type json = Yojson.Basic.t

  type path =
    | Index of int
    | Field of string

  let rec walk path (json : json) map_node =
    match path, json with
    | [], json -> map_node json
    | Index x::rest, `List next ->
      walk rest (try List.nth next x
                 with _ -> raise (Error NoSuchNode))
        map_node
    | Index x::rest, `Assoc next ->
      walk rest (try snd (List.nth next x)
                 with _ -> raise (Error NoSuchNode))
        map_node
    | Field x::rest, `Assoc next ->
      walk rest (try List.assoc x next
                 with _ -> raise (Error NoSuchNode))
        map_node
    | Index _::_, _
    | Field _::_, _ ->
      raise (Error InvalidNodeType)

  let any x = x

  let assoc = function
    | (`Assoc _) as x -> x
    | _ -> raise (Error InvalidNodeType)

  let string = function
    | `String s -> s
    | _ -> raise (Error InvalidNodeType)
end

(* "5432/tcp": [
 *   {
 *     "HostIp": "0.0.0.0",
 *     "HostPort": "32768"
 *   }
 * ] *)
let parse_ports (ports_json : json) =
  let open JsonWalker in
  match ports_json with
  | `Assoc xs -> begin
      xs |> List.fold_left
        (fun portmap (key, json) ->
           let host_ip = walk [Index 0; Field "HostIp"] json string in
           let host_port = walk [Index 0; Field "HostPort"] json string |> int_of_string in
           PortMap.add key { host_ip; host_port } portmap
        )
        PortMap.empty
    end
  | _ -> failwith "Expected associative table in Ports"

let create_db_container () : container_info =
  let run_channel =
    let args = "-c fsync=off -c full_page_writes=off" in
    let command = "docker run --rm -e POSTGRES_PASSWORD=test -p 5432 -d postgres:11 " ^ args in
    Unix.open_process_in command in
  let ci_id = input_line run_channel in
  OUnit2.assert_equal (Unix.close_process_in run_channel) (Unix.WEXITED 0);
  let inspect_channel = Unix.open_process_in ("docker inspect " ^ Filename.quote ci_id) in
  let inspect = Yojson.Basic.from_channel inspect_channel in
  let ci_ports = JsonWalker.(walk [Index 0; Field "NetworkSettings"; Field "Ports"] inspect assoc) |> parse_ports in
  { ci_id; ci_ports; }

let stop_db_container id =
  OUnit2.assert_equal (
    let channel = Unix.open_process_in ("docker stop " ^ Filename.quote id) in
    let _ignore = input_line channel in
    Unix.close_process_in channel) (Unix.WEXITED 0)

let valuefy f x =
  try `Value (f x)
  with exn -> `Exn exn

let unvaluefy = function
  | `Value x -> x
  | `Exn e -> raise e

let container_info = lazy (
  let container_info = create_db_container () in
  at_exit (fun () -> stop_db_container container_info.ci_id);
  container_info
)

type 'db_writer db_test_context = {
  db: 'db_writer;               (* at with_new_db we don't have this *)
  conninfo: string Lazy.t;
}

let retry f =
  let rec loop n exn =
    if n > 0 then (
      match f () with
      | x -> `Value x
      | exception (_ as exn) ->
        Unix.sleepf 1.0;
        loop (n - 1) (Some exn)
    ) else match exn with
      | None -> assert false
      | Some exn -> `Exn exn
  in
  unvaluefy (loop 5 None)

let create_new_database =
  let db_id_counter = ref 0 in
  fun conninfo ->
    let name = Printf.sprintf "test_db_%03d" !db_id_counter in
    let _ = incr db_id_counter in
    let pg = retry @@ fun () ->
      new Postgresql.connection ~conninfo ()
    in
    ignore (pg#exec ~expect:[Postgresql.Command_ok] (Printf.sprintf {|
CREATE DATABASE %s
|} (Db_writer.Internal.db_of_identifier name)));
    pg#finish;
    let conninfo_with_dbname = (conninfo ^ " dbname=" ^ name) in
    let pg = new Postgresql.connection ~conninfo:conninfo_with_dbname () in
    ignore (pg#exec ~expect:[Postgresql.Command_ok] {|
CREATE TABLE meas(time timestamptz NOT NULL);
CREATE UNIQUE INDEX meas_time_dx ON meas(time);
|});
    pg#finish;
    conninfo_with_dbname

let with_conninfo _ctx f =
  let pg_port = lazy ((PortMap.find "5432/tcp" (Lazy.force container_info).ci_ports).host_port) in
  let conninfo = lazy ("user=postgres password=test host=localhost port=" ^ string_of_int (Lazy.force pg_port)) in
  try
    f { db = (); conninfo }
  with Postgresql.Error error ->
    Printf.ksprintf OUnit2.assert_failure "Postgresql.Error: %s" (Postgresql.string_of_error error)

let with_new_db ctx f =
  with_conninfo ctx @@ fun { conninfo; db = () } ->
  let conninfo = lazy (create_new_database (Lazy.force conninfo)) in
  f { db = (); conninfo; }

let with_db_writer (ctx : OUnit2.test_ctxt) (f : Db_writer.t Lazy.t db_test_context -> 'a) : 'a =
  with_new_db ctx @@ fun { conninfo; _ } ->
  let db = lazy (Db_writer.create { Db_writer.conninfo = Lazy.force conninfo;
                                    time_field = "time" }) in
  let ret = valuefy f { db; conninfo } in
  if Lazy.is_val db then
    Db_writer.close (Lazy.force db);
  (match ret with
   | `Exn (Db_writer.Error error) ->
     OUnit2.logf ctx `Error "Db_writer.Error: %s" (Db_writer.string_of_error error)
   | _ -> ()
  );
  unvaluefy ret
