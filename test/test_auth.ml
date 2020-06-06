open OUnit2
open Influxdb_write_to_postgresql

let case ~user ~password ~token ~expect auth_request =
  let user, msg_user =
    match user with
    | `IncorrectUser -> Some "not test", "`IncorrectUser"
    | `CorrectUser -> Some "test1", "`CorrectUser"
    | `MissingUser -> None, "`MissingUser"
  in
  let password, msg_password =
    match password with
    | `IncorrectPassword -> Some "not password", "`IncorrectPassword"
    | `CorrectPassword -> Some "password1", "`CorrectPassword"
    | `MissingPassword -> None, "`MissingPassword"
  in
  let token, msg_token =
    match token with
    | `IncorrectToken -> Some "not token", "`IncorrectToken"
    | `CorrectToken1 -> Some "token1", "`CorrectToken1"
    | `CorrectToken2 -> Some "token2", "`CorrectToken2"
    | `MissingToken -> None, "`MissingToken"
  in
  let msg_expect =
    match expect with
    | Ok result -> "Ok " ^ Auth.show_result result
    | Error error -> "Error " ^ Auth.show_error error
  in
  let request =
    {
      Auth.user = user;
      password = password;
      token = token;
    }
  in
  let msg = Printf.sprintf "Grep for: %s, %s, %s -> %s" msg_user msg_password msg_token msg_expect in
  let result =
    try Ok (auth_request ~request)
    with Auth.Error error -> Error error
  in
  let printer = function
    | Ok result -> "Ok " ^ Auth.show_result result
    | Error error -> "Err " ^ Auth.show_error error
  in
  assert_equal ~printer ~msg
    expect
    result

let flip f a b = f b a

let user_pass_config =
  { Auth.users =
      let open Config in
      ["test1",
       {
         token = None;
         group = None;
         password = Some { type_ = Plain; password = "password1" };
         expires = None;
       }]
  }

let user_password_driver auth_request =
  flip List.iter [`IncorrectUser; `CorrectUser] @@ fun user ->
  flip List.iter [`IncorrectPassword; `CorrectPassword] @@ fun password ->
  (* writing this way helps the compiler test all cases in a searchable manner :-o *)
  let expect = match user, password, `MissingToken with
    | `IncorrectUser, `IncorrectPassword, `MissingToken -> Ok Auth.AuthFailed
    | `IncorrectUser, `CorrectPassword, `MissingToken -> Ok Auth.AuthFailed
    | `CorrectUser, `IncorrectPassword, `MissingToken -> Ok Auth.AuthFailed
    | `CorrectUser, `CorrectPassword, `MissingToken -> Ok Auth.AuthSuccess
  in
  let token = `MissingToken in
  case ~user ~password ~token ~expect auth_request

let testPlain _ctx =
  let auth = Auth.create user_pass_config in
  let context = { Auth.allowed_users = Some ["test1"; "test2"] } in
  user_password_driver @@ fun ~(request:Auth.request) ->
  Auth.permitted auth ~context ~request

let testBasic _ctx =
  let basic_of_request (request : Auth.request) =
    let headers = Cohttp.Header.init () in
    let base64enc = Cryptokit.Base64.encode_compact_pad () in
    Option.iter (fun user -> base64enc#put_string user) request.user;
    base64enc#put_string ":";
    Option.iter (fun password -> base64enc#put_string password) request.password;
    base64enc#finish;
    let base64 = base64enc#get_string in
    Cohttp.Header.add headers "Authorization" (Printf.sprintf "Basic %s" base64)
  in
  let auth = Auth.create user_pass_config in
  let context = { Auth.allowed_users = Some ["test1"; "test2"] } in
  user_password_driver @@ fun ~(request:Auth.request) ->
  let header = basic_of_request request in
  Auth.permitted_header auth ~context ~header

let token_config =
  { Auth.users =
      let open Config in
      [("test1",
        {
          token = Some "token1";
          group = None;
          password = None;
          expires = None;
        });
       ("test2",
        {
          token = Some "token2";
          group = None;
          password = None;
          expires = None;
        })]
  }

let token_driver auth_request =
  flip List.iter [`MissingToken; `IncorrectToken; `CorrectToken1] @@ fun token ->
  (* writing this way helps the compiler test all cases in a searchable manner :-o *)
  let expect = match `MissingUser, `MissingPassword, token with
    | `MissingUser, `MissingPassword, `MissingToken -> Error Auth.FailedToParseAuthorization
    | `MissingUser, `MissingPassword, `IncorrectToken -> Ok Auth.AuthFailed
    | `MissingUser, `MissingPassword, `CorrectToken1 -> Ok Auth.AuthSuccess
  in
  let user = `MissingUser in
  let password = `MissingPassword in
  case ~user ~password ~token ~expect auth_request

let testToken _ctx =
  let basic_of_request (request : Auth.request) =
    let headers = Cohttp.Header.init () in
    Cohttp.Header.add headers "Authorization" (Printf.sprintf "Token %s" (Option.value request.token ~default:""))
  in
  let auth = Auth.create token_config in
  let context = { Auth.allowed_users = Some ["test1"; "test2"] } in
  token_driver @@ fun ~(request:Auth.request) ->
  let header = basic_of_request request in
  Auth.permitted_header auth ~context ~header

let suite = "Db_auth" >::: [
  "testPlain" >:: testPlain;
  "testBasic" >:: testBasic;
  "testToken" >:: testToken;
]
