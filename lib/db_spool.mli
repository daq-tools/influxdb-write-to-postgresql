type t

type config = {
  databases: (string * Db_writer.config) list;
}

type error = Invalid_database_name of string

exception Error of error

val create : config -> t

type db_info = {
  db: Db_writer.t;
  release: unit -> unit;
}

val db : t -> string -> db_info option
