open Printf
open Devkit
open Lib

let log = Log.from "request_handler"

module Action = Action.Action (Api_remote.Github) (Api_remote.Slack)

let setup_http ~ctx ~signature ~port ~ip =
  let open Httpev in
  let connection = Unix.ADDR_INET (ip, port) in
  let%lwt () =
    Httpev.setup_lwt { default with name = "monorobot"; connection; access_log_enabled = false } (fun _http request ->
      let module Arg = Args (struct let req = request end) in
      let body r = Lwt.return (`Body r) in
      let ret ?(status = `Ok) ?(typ = "text/plain") ?extra r =
        let%lwt r = r in
        body @@ serve ~status ?extra request typ r
      in
      let _ret' ?extra r =
        let%lwt typ, r = r in
        body @@ serve ~status:`Ok ?extra request typ r
      in
      let _ret'' ?extra r =
        let%lwt status, typ, r = r in
        body @@ serve ~status ?extra request typ r
      in
      let ret_err status s = body @@ serve_text ~status request s in
      try%lwt
        let path =
          match Stre.nsplitc request.path '/' with
          | "" :: p -> p
          | _ -> Exn.fail "you are on a wrong path"
        in
        match request.meth, List.map Web.urldecode path with
        | _, [ "stats" ] -> ret @@ Lwt.return (sprintf "%s %s uptime\n" signature Devkit.Action.uptime#get_str)
        | `GET, [ "config" ] ->
          let repo_url = Arg.str "repo" |> Web.urldecode in
          ( match%lwt Action.print_config ctx repo_url with
          | Error (code, msg) -> ret_err code msg
          | Ok res -> ret ~typ:"application/json" (Lwt.return res)
          )
        | _, [ "github" ] ->
          log#info "%s" request.body;
          let%lwt () = Action.process_github_notification ctx request.headers request.body in
          ret (Lwt.return "ok")
        | _, [ "slack"; "events" ] ->
          log#info "%s" request.body;
          ret @@ Action.process_slack_event ctx request.headers request.body
        | _, _ ->
          log#error "unknown path : %s" (Httpev.show_request request);
          ret_err `Not_found "not found"
      with
      | Arg.Bad s ->
        log#error "bad parameter %S : %s" s (Httpev.show_request request);
        ret_err `Not_found (sprintf "bad parameter %s" s)
      | exn ->
        log#error ~exn "internal error : %s" (Httpev.show_request request);
        ret_err `Internal_server_error
          ( match exn with
          | Failure s -> s
          | Invalid_argument s -> s
          | exn -> Exn.str exn
          )
    )
  in
  Lwt.return_unit

let run ~ctx ~addr ~port =
  let ip = Unix.inet_addr_of_string addr in
  let signature = sprintf "listen %s:%d" (Unix.string_of_inet_addr ip) port in
  setup_http ~ctx ~signature ~port ~ip
