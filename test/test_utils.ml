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
    let command = "docker run --rm -e POSTGRES_PASSWORD=test -p 5432 -d timescale/timescaledb:latest-pg11 " ^ args in
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

let container_info = lazy (
  let container_info = create_db_container () in
  at_exit (fun () -> stop_db_container container_info.ci_id);
  container_info
)

let lwt_container_info = lazy (
  let container_info = create_db_container () in
  Lwt_main.at_exit (fun () -> stop_db_container container_info.ci_id; Lwt.return ());
  container_info
)

type 'db_writer db_test_context = {
  db: 'db_writer;               (* at with_new_db we don't have this *)
  db_spec: Db_writer.db_spec Lazy.t;
}

let retry f =
  let rec loop n exn =
    if n > 0 then (
      match f () with
      | x -> `Value x
      | exception (_ as exn) ->
        Unix.sleepf 1.0;
        loop (n - 1) (Some (exn, Printexc.get_raw_backtrace ()))
    ) else match exn with
      | None -> assert false
      | Some exn -> `Exn exn
  in
  Common.unvaluefy_exn (loop 10 None)

let create_new_database_exn =
  let db_id_counter = ref 0 in
  fun ?schema db_spec ->
    let name = Printf.sprintf "test_db_%d_%03d" (Unix.getpid ()) !db_id_counter in
    let _ = incr db_id_counter in
    let pg = retry @@ fun () ->
      Db_writer.Internal.new_pg_connection_exn db_spec
    in
    ignore (pg#exec ~expect:[Postgresql.Command_ok] (Printf.sprintf {|
CREATE DATABASE %s
|} (Db_writer.Internal.db_of_identifier_exn name :> string)));
    pg#finish;
    let conninfo_with_dbname =
      match db_spec with
      | Db_writer.DbInfo x -> Db_writer.DbInfo { x with db_name = name }
      | Db_writer.DbConnInfo x -> Db_writer.DbConnInfo (x ^ " dbname=" ^ name)
    in
    (match schema with
     | None -> ()
     | Some schema ->
       let pg = Db_writer.Internal.new_pg_connection_exn conninfo_with_dbname in
       ignore (pg#exec ~expect:[Postgresql.Command_ok] schema);
       pg#finish);
    conninfo_with_dbname

type db_spec_format =
  | DbSpecConnInfo
  | DbSpecInfo

let with_conninfo ?(container_info=container_info) ?(db_spec_format=DbSpecConnInfo) _ctx f =
  let pg_port = lazy ((PortMap.find "5432/tcp" (Lazy.force container_info).ci_ports).host_port) in
  let db_spec =
    lazy (
      match db_spec_format with
      | DbSpecConnInfo -> (Db_writer.DbConnInfo ("user=postgres password=test host=localhost port=" ^ string_of_int (Lazy.force pg_port)))
      | DbSpecInfo -> Db_writer.DbInfo { Db_writer.db_host = "localhost"; db_port = Lazy.force pg_port; db_user = "postgres"; db_password = "test"; db_name = ""; }) in
  try
    f { db = (); db_spec }
  with Postgresql.Error error ->
    Printf.ksprintf OUnit2.assert_failure "Postgresql.Error: %s" (Postgresql.string_of_error error)

let with_new_db ?container_info ?db_spec_format ctx schema f =
  with_conninfo ?container_info ?db_spec_format ctx @@ fun { db_spec; db = () } ->
  let db_spec = lazy (create_new_database_exn ?schema (Lazy.force db_spec)) in
  f { db = (); db_spec; }

let make_db_writer_config db_spec =
  { Db_writer.db_spec = Lazy.force db_spec;
    time_method = Config.TimestampTZ { time_field = "time" };
    tags_column = None;
    fields_column = None;
    create_table = None; }

let rec seq_of_gen : 'a CCIO.gen -> 'a Seq.t = fun gen () ->
  match gen () with
  | None -> Seq.Nil
  | Some value -> Seq.Cons (value, seq_of_gen gen)

let with_db_writer ?(make_config=make_db_writer_config) (ctx : OUnit2.test_ctxt) ?schema (f : Db_writer.t Lazy.t db_test_context -> 'a) : 'a =
  with_new_db ctx schema @@ fun { db_spec; _ } ->
  let (log_file, log_channel) = OUnit2.bracket_tmpfile ctx in
  let log_file_in = open_in log_file in
  Logging.setup_out_channel_logging log_channel;
  Logging.set_level (Some Logs.Debug);
  let db = lazy (Db_writer.create_exn (make_config db_spec)) in
  let ret = Common.valuefy f { db; db_spec } in
  Logging.stop_logging ();
  (match ret with
   | `Exn _ ->
     CCIO.(read_lines_gen log_file_in
           |> seq_of_gen
           |> Seq.iter @@ fun line ->
           OUnit2.logf ctx `Info "%s" line;
          );
   | _ -> ()
  );
  close_in log_file_in;
  if Lazy.is_val db then
    Db_writer.close (Lazy.force db);
  (match ret with
   | `Exn (Db_writer.Error error, raw_backtrace) ->
     OUnit2.logf ctx `Error "Db_writer.Error: %s\nBacktrace: %s" (Db_writer.string_of_error error) (Printexc.raw_backtrace_to_string raw_backtrace)
   | `Exn (Sql_types.Error error, raw_backtrace) ->
     OUnit2.logf ctx `Error "Sql_types.Error: %s\nBacktrace: %s" (Sql_types.string_of_error error) (Printexc.raw_backtrace_to_string raw_backtrace)
   | _ -> ()
  );
  Common.unvaluefy_exn ret
