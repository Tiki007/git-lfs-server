(*
 * Copyright (c) 2015 Stanislav Artemkin <artemkin@gmail.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 *)

open Core
open Async
open Cohttp
open Cohttp_async

open Lfs_aux

module Json = struct
  let from_string str =
    try Some (Yojson.Safe.from_string str) with _ -> None

  let to_string json =
    Yojson.pretty_to_string json

  let get_value assoc_lst key =
    List.Assoc.find assoc_lst ~equal:String.equal key

  let get_string assoc_lst key =
    match get_value assoc_lst key with
    | Some (`String str) -> Some str
    | _ -> None

  let get_int assoc_lst key =
    match get_value assoc_lst key with
    | Some (`Int i) -> Some (Int64.of_int i)
    | Some (`Intlit str) -> Option.try_with (fun () -> Int64.of_string str)
    | _ -> None

  let error msg =
    let msg = `Assoc [ "message", `String msg ] in
    to_string msg

  let metadata ~oid ~size ~self_url ~download_url =
    let msg = `Assoc [
        "oid", `String oid;
        "size", `Intlit (Int64.to_string size);
        "_links", `Assoc [
          "self", `Assoc [ "href", `String (Uri.to_string self_url) ];
          "download", `Assoc [ "href", `String (Uri.to_string download_url) ]
        ]
      ] in
    to_string msg

  let download url =
    let msg = `Assoc [
        "_links", `Assoc [
          "download", `Assoc [ "href", `String (Uri.to_string url) ]
        ]
      ] in
    to_string msg

  let upload url =
    let url = Uri.to_string url in
    let msg = `Assoc [
        "_links", `Assoc [
          "upload", `Assoc [ "href", `String url ];
          "verify", `Assoc [ "href", `String url ]
        ]
      ] in
    to_string msg

  let batch_upload_ok oid size url =
    let url = Uri.to_string url in
    `Assoc [
      "oid", `String oid;
      "size", `Intlit (Int64.to_string size);
      "actions", `Assoc [
        "upload", `Assoc [ "href", `String url ];
        "verify", `Assoc [ "href", `String url ]
      ]
    ]

  let batch_upload_exists oid size =
    `Assoc [
      "oid", `String oid;
      "size", `Intlit (Int64.to_string size);
    ]

  let batch_upload_error oid size =
    `Assoc [
      "oid", `String oid;
      "size", `Intlit (Int64.to_string size);
      "error", `Assoc [
        "code", `Int 422;
        "message", `String "Wrong object size"
      ]
    ]

  let parse_operation = function
    | "download" -> Some `Download
    | "upload" -> Some `Upload
    | _ -> None

  let parse_object = function
    | `Assoc lst ->
      let oid = Option.filter (get_string lst "oid") ~f:is_sha256_hex_digest in
      let size = get_int lst "size" in
      Option.both oid size
    | _ -> None

  let parse_objects = function
    | `List lst -> Option.all (List.map lst ~f:parse_object)
    | _ -> None

  let parse_batch_req str =
    match from_string str with
    | Some (`Assoc lst) ->
      let operation = (Option.find_map (get_string lst "operation") ~f:parse_operation) in
      let objects = (Option.find_map (get_value lst "objects") ~f:parse_objects) in
      Option.both operation objects
    | _ -> None

  let parse_oid_size str =
    match from_string str with
    | Some json -> parse_object json
    | _ -> None

end

let add_content_type headers content_type =
  Header.add headers "content-type" content_type

let respond ~headers ~body ~code =
  Server.respond ~headers ~body code >>| fun resp ->
  resp, `Log_ok code

let respond_ok ~code =
  Server.respond code >>| fun resp ->
  resp, `Log_ok code

let respond_error ~code =
  Server.respond code >>| fun resp ->
  resp, `Log_error (code, "")

let prepare_string_respond ~meth ~code msg =
  let headers = add_content_type (Header.init ()) "application/vnd.git-lfs+json" in
  let body = match meth with `HEAD -> `Empty | _ -> `String msg in
  Server.respond ~headers ~body code

let respond_with_string ~meth ~code msg =
  prepare_string_respond ~meth ~code msg >>| fun resp ->
  resp, `Log_ok code

let respond_error_with_message ~meth ~code msg =
  prepare_string_respond ~meth ~code @@ Json.error msg >>| fun resp ->
  resp, `Log_error (code, msg)

let mkdir_if_needed dirname =
  try_with ~run:`Now (fun () -> Unix.stat dirname) >>= function
  | Ok _ -> Deferred.unit
  | Error _ ->
    try_with ~run:`Now (fun () -> Unix.mkdir dirname)
    >>= fun _ -> Deferred.unit

let get_oid_prefixes ~oid =
  (String.prefix oid 2, String.sub oid ~pos:2 ~len:2)

let make_objects_dir_if_needed ~root ~oid =
  let (oid02, oid24) = get_oid_prefixes ~oid in
  let dir02 = Filename.of_parts [root; "/objects"; oid02] in
  let dir24 = Filename.concat dir02 oid24 in
  mkdir_if_needed dir02 >>= fun () ->
  mkdir_if_needed dir24

let get_object_filename ~root ~oid =
  let (oid02, oid24) = get_oid_prefixes ~oid in
  let oid_path = Filename.of_parts [oid02; oid24; oid] in
  Filename.of_parts [root; "/objects"; oid_path]

let get_temp_filename ~root ~oid =
  Filename.of_parts [root; "/temp"; oid]

let check_object_file_stat ~root ~oid =
  let filename = get_object_filename ~root ~oid in
  try_with ~run:`Now (fun () -> Unix.stat filename)

let get_download_url uri oid =
  Uri.with_path uri @@ Filename.concat "/data/objects" oid

let respond_object_metadata ~root ~meth ~uri ~oid =
  check_object_file_stat ~root ~oid >>= function
  | Error _ -> respond_error_with_message ~meth ~code:`Not_found "Object not found"
  | Ok stat ->
    let download_url = get_download_url uri oid in
    respond_with_string ~meth ~code:`OK
    @@ Json.metadata ~oid ~size:(Unix.Stats.size stat) ~self_url:uri ~download_url

let respond_object ~root ~meth ~oid =
  let filename = get_object_filename ~root ~oid in
  try_with ~run:`Now
    (fun () ->
       Reader.open_file filename
       >>= fun rd ->
       let headers = add_content_type (Header.init ()) "application/octet-stream" in
       match meth with
       | `GET ->
         respond ~headers ~body:(`Pipe (Reader.pipe rd)) ~code:`OK
       | `HEAD ->
         Reader.close rd >>= fun () ->
         respond ~headers ~body:`Empty ~code:`OK)
  >>= function
  | Ok res -> return res
  | Error _ -> respond_error_with_message ~meth ~code:`Not_found "Object not found"

let parse_path path =
  match String.rsplit2 path ~on:'/' with
  | Some ("/objects", "batch") -> `Batch_path
  | Some ("/objects", oid) ->
    if is_sha256_hex_digest oid then `Default_path oid else `Wrong_path
  | Some ("/data/objects", oid) ->
    if is_sha256_hex_digest oid then `Download_path oid else `Wrong_path
  | Some ("", "objects") -> `Post_path
  | _ -> `Wrong_path

let handle_get root meth uri =
  let path = Uri.path uri in
  match parse_path path with
  | `Default_path oid -> respond_object_metadata ~root ~meth ~uri ~oid
  | `Download_path oid -> respond_object ~root ~meth ~oid
  | `Post_path | `Wrong_path | `Batch_path ->
    respond_error_with_message ~meth ~code:`Not_found "Wrong path"

let handle_verify root meth oid =
  check_object_file_stat ~root ~oid
  >>= function
  | Ok _ -> respond_ok ~code:`OK
  | Error _ ->
    respond_error_with_message ~meth ~code:`Not_found
      "Verification failed: object not found"

let handle_batch_download _root meth _uri _objects =
  respond_error_with_message ~meth ~code:`Bad_request "Not implemented"

let handle_batch_upload root meth uri objects =
  let aux (oid, size) =
    check_object_file_stat ~root ~oid >>= function
    | Ok stat when (Unix.Stats.size stat = size) ->
      return (Json.batch_upload_exists oid size)
    | Ok _ ->
      return (Json.batch_upload_error oid size)
    | Error _ ->
      let url = Uri.with_path uri @@ Filename.concat "/objects" oid in
      return (Json.batch_upload_ok oid size url)
  in
  let lst = List.map objects ~f:aux in
  Deferred.all lst >>= fun objects ->
  let json =
    `Assoc [
      "transfer", `String "basic";
      "objects", `List objects
    ]
  in
  respond_with_string ~meth ~code:`OK @@ Json.to_string json

let handle_batch root meth uri body =
  Body.to_string body >>= fun body ->
  match Json.parse_batch_req body with
  | None ->
    respond_error_with_message ~meth ~code:`Bad_request "Invalid body"
  | Some (operation, objects) ->
    match operation with
    | `Download -> handle_batch_download root meth uri objects
    | `Upload -> handle_batch_upload root meth uri objects

let handle_post root meth uri body =
  let path = Uri.path uri in
  match parse_path path with
  | `Download_path _ | `Wrong_path ->
    respond_error_with_message ~meth ~code:`Not_found "Wrong path"
  | `Default_path oid -> handle_verify root meth oid
  | `Batch_path -> handle_batch root meth uri body
  | `Post_path ->
    Body.to_string body >>= fun body ->
    match Json.parse_oid_size body with
    | None -> respond_error_with_message ~meth ~code:`Bad_request "Invalid body"
    | Some (oid, size) ->
      check_object_file_stat ~root ~oid >>= function
      | Ok stat when (Unix.Stats.size stat = size) ->
        let url = get_download_url uri oid in
        respond_with_string ~meth ~code:`OK @@ Json.download url
      | Ok _ ->
        respond_error_with_message ~meth ~code:`Bad_request "Wrong object size"
      | Error _ ->
        let url = Uri.with_path uri @@ Filename.concat "/objects" oid in
        respond_with_string ~meth ~code:`Accepted @@ Json.upload url

let handle_put root meth uri body req =
  let path = Uri.path uri in
  let headers = Request.headers req in
  match Header.get_content_range headers with
  | None -> respond_error ~code:`Bad_request
  | Some bytes_to_read ->
    match parse_path path with
    | `Download_path _ | `Post_path | `Wrong_path | `Batch_path ->
      respond_error_with_message ~meth ~code:`Not_found "Wrong path"
    | `Default_path oid ->
      check_object_file_stat ~root ~oid >>= function
      | Ok _ -> respond_ok ~code:`OK (* already exist *)
      | Error _ ->
        let filename = get_object_filename ~root ~oid in
        let temp_file = get_temp_filename ~root ~oid in
        make_objects_dir_if_needed ~root ~oid >>= fun () ->
        with_file_atomic ~temp_file filename ~f:(fun w ->
            let hash = SHA256.create () in
            Pipe.transfer (Body.to_pipe body) (Writer.pipe w) ~f:(fun str ->
                SHA256.feed hash str;
                str) >>| fun () ->
            let bytes_received = Int63.to_int64 (Writer.bytes_received w) in
            let hexdigest = SHA256.hexdigest hash in
            if bytes_received <> bytes_to_read
            then Error (sprintf "Incomplete upload of %s" oid)
            else if hexdigest <> oid
            then Error (sprintf "Content doesn't match SHA-256 digest: %s" oid)
            else (Ok ()))
        >>= function
        | Ok () -> respond_ok ~code:`Created
        | Error msg -> respond_error_with_message ~meth ~code:`Bad_request msg

let serve_client ~root ~fix_uri ~auth ~body ~req =
  let uri = Request.uri req in
  let meth = Request.meth req in
  if Option.is_none (Uri.host uri) then
    respond_error_with_message ~meth ~code:`Bad_request "Wrong host"
  else if not (auth req) then
    respond_error_with_message ~meth ~code:`Unauthorized "The authentication credentials are incorrect"
  else
    let uri = fix_uri uri in
    match meth with
    | (`GET as meth) | (`HEAD as meth) -> handle_get root meth uri
    | `POST -> handle_post root meth uri body
    | `PUT -> handle_put root meth uri body req
    | _ -> respond_error ~code:`Method_not_allowed

let serve_client_and_log_respond ~root ~fix_uri ~auth ~logger ~body (`Inet (client_host, _)) req =
  serve_client ~root ~fix_uri ~auth ~body ~req >>| fun (resp, log_info) ->
  let client_host = UnixLabels.string_of_inet_addr client_host in
  let meth = Code.string_of_method @@ Request.meth req in
  let path = Uri.path @@ Request.uri req in
  let version = Code.string_of_version @@ Request.version req in
  (match log_info with
   | `Log_ok status ->
     let status = Code.string_of_status status in
     Log.info logger "%s \"%s %s %s\" %s" client_host meth path version status
   | `Log_error (status, msg) ->
     let status = Code.string_of_status status in
     Log.error logger "%s \"%s %s %s\" %s \"%s\"" client_host meth path version status msg);
  resp

let determine_mode cert key =
  match (cert, key) with
  | Some c, Some k -> return (`OpenSSL (`Crt_file_path c, `Key_file_path k))
  | None, None -> return `TCP
  | _ ->
    eprintf "Error: must specify both certificate and key for HTTPS\n";
    shutdown 0;
    Deferred.never ()

let mode_to_string = function
  | `OpenSSL _ -> "HTTPS"
  | `TCP -> "HTTP"

let scheme_and_port mode port =
  let with_default_port default_port =
    if port = default_port then None else Some port
  in
  match mode with
  | `OpenSSL _ -> Some "https", (with_default_port 443)
  | `TCP -> Some "http", (with_default_port 80)

let authorize_with_pam pam req =
  match Request.headers req |> Header.get_authorization with
  | Some `Basic (user, passwd) ->
    (try Simple_pam.authenticate pam user passwd; true with _ -> false)
  | None | Some `Other _ -> false

let start_server root host port cert key pam verbose () =
  let root = Filename.concat root "/.lfs" in
  mkdir_if_needed root >>= fun () ->
  mkdir_if_needed @@ Filename.concat root "/objects" >>= fun () ->
  mkdir_if_needed @@ Filename.concat root "/temp" >>= fun () ->
  determine_mode cert key >>= fun mode ->
  let logging_level = if verbose then `Info else `Error in
  let logger =
    Log.create
      ~on_error:`Raise
      ~output:[Log.Output.stdout ()]
      ~level:logging_level in
  Log.raw logger "Listening for %s on %s:%d" (mode_to_string mode) host port;
  Unix.Inet_addr.of_string_or_getbyname host
  >>= fun host ->
  let listen_on = Tcp.Where_to_listen.create
      ~socket_type:Socket.Type.tcp
      ~address:(`Inet (host, port))
      ~listening_on:(fun _ -> port)
  in
  let handle_error address ex =
    match address with
    | `Unix _ -> assert false
    | `Inet (client_host, _) ->
      let client_host = UnixLabels.string_of_inet_addr client_host in
      match Monitor.extract_exn ex with
      | Failure err -> Log.error logger "%s Failure: %s" client_host err
      | Unix.Unix_error (_, err, _) -> Log.error logger "%s Unix_error: %s" client_host err
      | ex -> Log.error logger "%s Exception: %s" client_host (Exn.to_string ex)
  in
  let fix_uri =
    let scheme, port = scheme_and_port mode port in
    fun uri ->
      let uri = Uri.with_scheme uri scheme in
      Uri.with_port uri port
  in
  let auth = match pam with
    | None -> (fun _req -> true)
    | Some pam -> authorize_with_pam pam
  in
  Signal.handle [Signal.term; Signal.int] ~f:(fun _ ->
      Log.raw logger "Shutting down...";
      Shutdown.shutdown 0);
  Server.create
    ~on_handler_error:(`Call handle_error)
    ~mode:(mode :> Conduit_async.server)
    listen_on
    (serve_client_and_log_respond ~root ~fix_uri ~auth ~logger)
  >>= fun _ -> Deferred.never ()

let () =
  Command.async
    ~summary:"Start Git LFS server"
    Command.Spec.(
      empty
      +> anon (maybe_with_default "." ("root" %: string))
      +> flag "-s" (optional_with_default "127.0.0.1" string) ~doc:"address IP address to listen on"
      +> flag "-p" (optional_with_default 8080 int) ~doc:"port TCP port to listen on"
      +> flag "-cert" (optional file) ~doc:"file File of certificate for https"
      +> flag "-key" (optional file) ~doc:"file File of private key for https"
      +> flag "-pam" (optional string) ~doc:"service PAM service name for user authentication"
      +> flag "-verbose" (no_arg) ~doc:" Verbose logging"
    )
    start_server
  |> fun command -> Command.run ~version:Lfs_config.version ~build_info:"Master" command

