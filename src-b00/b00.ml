(*---------------------------------------------------------------------------
   Copyright (c) 2018 The b0 programmers. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
   %%NAME%% %%VERSION%%
  ---------------------------------------------------------------------------*)

open B0_std
open B000

module Env = struct
  type tool_lookup = Cmd.tool -> (Fpath.t, string) result

  let env_tool_lookup ?sep ?(var = "PATH") env =
    let search_path = match String.Map.find var env with
    | exception Not_found -> "" | s -> s
    in
    match Fpath.list_of_search_path ?sep search_path with
    | Error _ as e -> fun _ -> e
    | Ok search -> fun tool -> Os.Cmd.must_find_tool ~search tool

  type t =
    { env : Os.Env.t;
      forced_env : Os.Env.t;
      lookup : tool_lookup }

  let memo lookup =
    let memo = Hashtbl.create 91 in
    fun tool -> match Hashtbl.find memo tool with
    | exception Not_found -> let p = lookup tool in Hashtbl.add memo tool p; p
    | p -> p

  let v ?lookup ?(forced_env = String.Map.empty) env =
    let lookup = match lookup with None -> env_tool_lookup env | Some l -> l in
    let lookup = memo lookup in
    { env; forced_env; lookup }

  let env e = e.env
  let forced_env e = e.forced_env
  let tool e l = e.lookup l
end

module Tool = struct
  type env_vars = string list
  let tmp_vars = ["TMPDIR"; "TEMP"; "TMP"]

  type response_file =
    { to_file : Cmd.t -> string;
      cli : Fpath.t -> Cmd.t; }

  let response_file_of to_file cli = { to_file; cli }
  let args0 =
    let to_file cmd = String.concat "\x00" (Cmd.to_list cmd) ^ "\x00" in
    let cli f = Cmd.(arg "-args0" %% path f) in
    { to_file; cli }

  type t =
    { name : Fpath.t;
      vars : env_vars;
      shielded_vars : env_vars;
      response_file : response_file option; }

  let v ?response_file ?(shielded_vars = tmp_vars) ?(vars = []) name =
    { name; vars; shielded_vars; response_file }

  let by_name ?response_file ?shielded_vars ?vars name =
    match Fpath.is_seg name with
    | false -> Fmt.invalid_arg "%S: tool is not a path segment" name
    | true -> v ?shielded_vars ?vars (Fpath.v name)

  let name t = t.name
  let vars t = t.vars
  let shielded_vars t = t.shielded_vars
  let response_file t = t.response_file
  let read_env t env =
    let add_var acc var = match String.Map.find var env with
    | v -> String.Map.add var v acc
    | exception Not_found -> acc
    in
    let relevant = List.fold_left add_var String.Map.empty t.vars in
    let all = List.fold_left add_var relevant t.shielded_vars in
    all, relevant
end

module Futs : sig
  type t
  type 'a fut
  type 'a fut_set
  val create : ?rand:Random.State.t -> unit -> t
  val fut : t -> 'a fut * 'a fut_set
  val fut_value : 'a fut -> 'a option
  val fut_wait : 'a fut -> ('a -> unit) -> unit
  val fut_set : 'a fut_set -> 'a -> unit
  val stir : t -> (unit -> unit) option
end = struct
  module Fut_id = struct
    type t = int
    let compare : int -> int -> int = compare
  end
  module Fmap = Map.Make (Fut_id)

  type 'a fut =
    { id : Fut_id.t;
      mutable value : 'a option;
      mutable konts : ('a -> unit) list;
      futs : t; }
  and 'a fut_set = 'a fut
  and e_fut = F : 'a fut -> e_fut
  and t =
    { mutable next : Fut_id.t;
      mutable waiting : e_fut Fmap.t;
      mutable kready : (unit -> unit) Rqueue.t; }

  let create ?rand () =
    { next = 0; waiting = Fmap.empty ; kready = Rqueue.empty ?rand () }

  let fut fs =
    let id = fs.next in
    let f = { id; value = None; konts = []; futs = fs} in
    (fs.next <- fs.next + 1; fs.waiting <- Fmap.add id (F f) fs.waiting; f, f)

  let fut_value f = f.value
  let fut_wait f k = match f.value with
  | Some v -> Rqueue.add f.futs.kready (fun () -> k v)
  | None -> f.konts <- k :: f.konts

  let fut_set f v = match f.value with
  | Some _ -> invalid_arg "fut value already set"
  | None ->
      f.value <- Some v;
      match Fmap.find f.id f.futs.waiting with
      | exception Not_found -> assert false
      | (F f) ->
          f.futs.waiting <- Fmap.remove f.id f.futs.waiting;
          let v = Option.get f.value in
          let add_kont k = Rqueue.add f.futs.kready (fun () -> k v) in
          List.iter add_kont f.konts;
          ()

  let stir fs = Rqueue.take fs.kready
end

module Memo = struct
  type feedback =
  [ `Miss_tool of Tool.t * string
  | `Op_cache_error of Op.t * string
  | `Op_complete of Op.t ]

  type t = { c : ctx; m : memo }
  and ctx = { group : Op.group }
  and memo =
    { clock : Time.counter;
      cpu_clock : Time.cpu_counter;
      feedback : feedback -> unit;
      cwd : Fpath.t;
      env : Env.t ;
      guard : Guard.t;
      reviver : Reviver.t;
      exec : Exec.t;
      futs : Futs.t;
      mutable finished : bool;
      mutable op_id : int;
      mutable ops : Op.t list; }

  let create ?clock ?cpu_clock:cc ~feedback ~cwd env guard reviver exec =
    let clock = match clock with None -> Time.counter () | Some c -> c in
    let cpu_clock = match cc with None -> Time.cpu_counter () | Some c -> c in
    let futs = Futs.create () and op_id = 0 and  ops = [] in
    let c = { group = "" } in
    let m =
      { clock; cpu_clock; feedback; cwd; env; guard; reviver; exec; futs;
        finished = false; op_id; ops; }
    in
    { c; m }

  let memo
      ?(hash_fun = (module Hash.Xxh_64 : Hash.T)) ?env ?cwd ?cache_dir
      ?trash_dir ?(jobs = 4) ?feedback ()
    =
    let feedback = match feedback with | Some f -> f | None -> fun _ -> () in
    let fb_cache = (feedback :> File_cache.feedback -> unit) in
    let fb_exec = (feedback :> Exec.feedback -> unit) in
    let fb_memo = (feedback :> feedback -> unit) in
    let clock = Time.counter () in
    let env = match env with None -> Os.Env.current () | Some env -> Ok env in
    let cwd = match cwd with None -> Os.Dir.cwd () | Some cwd -> Ok cwd in
    Result.bind env @@ fun env ->
    Result.bind cwd @@ fun cwd ->
    let cache_dir = match cache_dir with
    | None -> Fpath.(cwd / "_b0" / ".cache") | Some d -> d
    in
    let trash_dir = match trash_dir with
    | None -> Fpath.(cwd / "_b0" / ".trash") | Some d -> d
    in
    Result.bind (File_cache.create ~feedback:fb_cache cache_dir) @@ fun cache ->
    let env = Env.v env in
    let guard = Guard.create () in
    let reviver = Reviver.create clock hash_fun cache in
    let trash = Trash.create trash_dir in
    let exec = Exec.create ~clock ~feedback:fb_exec ~trash ~jobs () in
    Ok (create ~clock ~feedback:fb_memo ~cwd env guard reviver exec)

  let clock m = m.m.clock
  let cpu_clock m = m.m.cpu_clock
  let env m = m.m.env
  let reviver m = m.m.reviver
  let guard m = m.m.guard
  let exec m = m.m.exec
  let trash m = Exec.trash m.m.exec
  let delete_trash ~block m = Trash.delete ~block (trash m)
  let hash_string m s = Reviver.hash_string m.m.reviver s
  let hash_file m f = Reviver.hash_file m.m.reviver f
  let ops m = m.m.ops
  let timestamp m = Time.count m.m.clock
  let new_op_id m = let id = m.m.op_id in m.m.op_id <- id + 1; id
  let group m = m.c.group
  let with_group m group = { c = { group }; m = m.m }
  let finished m = m.m.finished
  let add_op m o = m.m.ops <- o :: m.m.ops; Guard.add m.m.guard o

  (* Fibers *)

  type 'a fiber = ('a -> unit) -> unit
  exception Fail

  let notify_op m ?k kind msg =
    let k = match k with None -> None | Some k -> Some (fun o -> k ()) in
    let id = new_op_id m and created = timestamp m in
    let o = Op.Notify.v_op ~id ~group:m.c.group ~created ?k kind msg in
    add_op m o

  let fail m fmt =
    let k msg = notify_op m `Fail msg; raise Fail in
    Fmt.kstr k fmt

  let fail_if_error m = function Ok v -> v | Error e -> fail m "%s" e

  let invoke_k m ~pp_kind k v = try k v with
  | Stack_overflow as e -> raise e
  | Out_of_memory as e -> raise e
  | Sys.Break as e -> raise e
  | Fail -> ()
  | e ->
      let bt = Printexc.get_raw_backtrace () in
      let err =
        Fmt.str "@[<v>%a raised unexpectedly:@,%a@]"
          pp_kind v Fmt.exn_backtrace (e, bt)
      in
      notify_op m `Fail err

  let run_fiber m f =
    let pp_kind ppf () = Fmt.string ppf "Toplevel fiber" in
    invoke_k m ~pp_kind f ()

  let continue_fut m k =
    let pp_kind ppf () = Fmt.string ppf "Future waiter" in
    invoke_k m ~pp_kind k ()

  let continue_op m o =
    let pp_kind ppf o = Fmt.pf ppf "Continuation of operation %d" (Op.id o) in
    List.iter (Guard.set_file_ready m.m.guard) (Op.writes o);
    m.m.feedback (`Op_complete o);
    invoke_k m ~pp_kind Op.invoke_k o

  let discontinue_op m o =
    List.iter (Guard.set_file_never m.m.guard) (Op.writes o);
    Op.discard_k o; m.m.feedback (`Op_complete o)

  let finish_op m o = match Op.status o with
  | Op.Executed ->
      if Op.revived o then continue_op m o else
      begin match Hash.equal (Op.hash o) Hash.nil with
      | true ->
          begin match Op.did_not_write o with
          | [] -> continue_op m o
          | miss ->
              Op.set_status o (Op.Failed (Op.Missing_writes miss));
              discontinue_op m o
          end
      | false ->
          match Reviver.record m.m.reviver o with
          | Ok true -> continue_op m o
          | Ok false ->
              let miss = Op.did_not_write o in
              Op.set_status o (Op.Failed (Op.Missing_writes miss));
              discontinue_op m o
          | Error e ->
              m.m.feedback (`Op_cache_error (o, e));
              begin match Op.did_not_write o with
              | [] -> continue_op m o
              | miss ->
                  Op.set_status o (Op.Failed (Op.Missing_writes miss));
                  discontinue_op m o
              end
      end
  | Op.Aborted | Op.Failed _ -> discontinue_op m o
  | Op.Waiting -> assert false

  let submit_op m o = match Op.status o with
  | Op.Aborted -> finish_op m o
  | Op.Waiting ->
      begin match Reviver.hash_op m.m.reviver o with
      | Error e ->
          (* FIXME Does this report errors cleanly ? We really want to
             be able to say which reads were supposed to be there and are not *)
          m.m.feedback (`Op_cache_error (o, e));
          Op.set_status o Op.Aborted; (* FIXME add a case *)
          finish_op m o
      | Ok hash ->
          Op.set_hash o hash;
          begin match Reviver.revive m.m.reviver o with
          | Ok None -> Exec.schedule m.m.exec o
          | Ok (Some _) -> finish_op m o
          | Error e ->
              m.m.feedback (`Op_cache_error (o, e));
              Exec.schedule m.m.exec o
          end
      end
  | Op.Executed | Op.Failed _ -> assert false

  (* XXX we may blow stack continuations can add which stirs.
     XXX futures make it even worse. *)

  let rec stir ~block m = match Guard.allowed m.m.guard with
  | Some o -> submit_op m o; stir ~block m
  | None ->
      match Exec.collect m.m.exec ~block with
      | Some o -> finish_op m o; stir ~block m
      | None ->
          match Futs.stir m.m.futs with
          | Some k -> continue_fut m k; stir ~block m
          | None -> ()

  let add_op_and_stir m o = add_op m o; stir ~block:false m

  (* Finishing the memo *)

  type finish_error =
  | Failures
  | Cycle of B000.Op.t list
  | Never_became_ready of Fpath.Set.t
  (* The type [finish_error] reports memo finish error conditions.
     Formally more than one of these condition may be true at the same
     time. It is however important not to try to detect and report
     [Never_became_ready] when [Failures] happens as those files that
     never became ready may be created by continuations of the
     failures and that would not lead the user to focus on the right
     thing. It's also better to report [Cycle]s before for this reason. *)

  let find_finish_condition os =
    let rec loop ws = function
    | [] -> if ws <> [] then Error (`Waiting ws) else (Ok ())
    | o :: os ->
        match Op.status o with
        | Op.Executed -> loop ws os
        | Op.Waiting -> loop (o :: ws) os
        | Op.Aborted | Op.Failed _ -> Error (`Failures)
    in
    loop [] os

  let finish m =
    stir ~block:true m;
    m.m.finished <- true;
    (* Any Waiting operation is guaranteed to be guarded at that point. *)
    match find_finish_condition m.m.ops with
    | Ok _ as v  -> assert (Futs.stir m.m.futs = None); v
    | Error `Failures -> Error Failures
    | Error (`Waiting ws) ->
        match Op.find_read_write_cycle ws with
        | Some os -> Error (Cycle ws)
        | None -> Error (Never_became_ready (Op.unwritten_reads ws))


  (* Notifications *)

  let notify ?k m kind fmt = Fmt.kstr (notify_op m ?k kind) fmt

  (* Files *)

  let file_ready m p = Guard.set_file_ready m.m.guard p
  let read m file k =
    let id = new_op_id m and created = timestamp m in
    let k o =
      let r = Op.Read.get o in
      let data = Op.Read.data r in
      Op.Read.discard_data r; k data
    in
    let o = Op.Read.v_op ~id ~group:m.c.group ~created ~k file in
    add_op_and_stir m o

  let wait_files m files k =
    let id = new_op_id m and created = timestamp m and k o = k () in
    let o = Op.Wait_files.v_op ~id ~group:m.c.group ~created ~k files in
    add_op_and_stir m o

  let write m ?(stamp = "") ?(reads = []) ?(mode = 0o644) write d =
    let id = new_op_id m and group = m.c.group and created = timestamp m in
    let o = Op.Write.v_op ~id ~group ~created ~stamp ~reads ~mode ~write d in
    add_op_and_stir m o

  let copy m ?(mode = 0o644) ?linenum ~src dst =
    let id = new_op_id m and group = m.c.group and created = timestamp m in
    let o = Op.Copy.v_op ~id ~group ~created ~mode ~linenum ~src dst in
    add_op_and_stir m o

  let mkdir m ?(mode = 0o755) dir k =
    let id = new_op_id m and created = timestamp m and k o = k () in
    let o = Op.Mkdir.v_op ~id ~group:m.c.group ~created ~k ~mode dir in
    add_op_and_stir m o

  let delete m p k =
    let id = new_op_id m and created = timestamp m and k o = k () in
    let o = Op.Delete.v_op ~id ~group:m.c.group ~created ~k p in
    add_op_and_stir m o

  (* FIXME better strategy to deal with builded tools. If the tool is a
     path check for readyness if not add it to the operations reads.
     I also suspect the tool lookup approach is not exactly right at
     the moment. Maybe this will clear up when we get the configuration
     story in. *)
  type _tool =
  { tool : Tool.t;
    tool_file : Fpath.t;
    tool_env : Os.Env.assignments;
    tool_relevant_env : Os.Env.assignments; }

  type tool =
  | Miss of Tool.t * string
  | Tool of _tool

  type cmd = { cmd_tool : tool; cmd_args : Cmd.t }

  let tool_env m t =
    let env = Env.env m.m.env in
    let tool_env, relevant = Tool.read_env t env in
    let forced_env = Env.forced_env m.m.env in
    let tool_env = Os.Env.override tool_env ~by:forced_env in
    let relevant = Os.Env.override relevant ~by:forced_env in
    tool_env, relevant

  let spawn_env m cmd_tool = function
  | None -> cmd_tool.tool_env, cmd_tool.tool_relevant_env
  | Some spawn_env ->
      let env = Env.env m.m.env in
      let tool_env, relevant = Tool.read_env cmd_tool.tool env in
      let forced_env = Env.forced_env m.m.env in
      let tool_env = Os.Env.override tool_env ~by:spawn_env in
      let tool_env = Os.Env.override tool_env ~by:forced_env in
      let relevant = Os.Env.override relevant ~by:spawn_env in
      let relevant = Os.Env.override relevant ~by:forced_env in
      Os.Env.to_assignments tool_env, Os.Env.to_assignments relevant

  let tool m tool =
    let cmd_tool = match Env.tool m.m.env (Tool.name tool) with
    | Error e -> Miss (tool, e)
    | Ok tool_file ->
        let tool_env, tool_relevant_env = tool_env m tool in
        let tool_env = Os.Env.to_assignments tool_env in
        let tool_relevant_env = Os.Env.to_assignments tool_relevant_env in
        Tool { tool; tool_file; tool_env; tool_relevant_env }
    in
    fun cmd_args -> { cmd_tool; cmd_args }

  let tool_opt m t = match Env.tool m.m.env (Tool.name t) with
  | Error e (* FIXME distinguish no lookup from errors *) -> None
  | Ok _ -> Some (tool m t)

  let spawn
      m ?(stamp = "") ?(reads = []) ?(writes = []) ?env ?cwd ?stdin
      ?(stdout = `Ui) ?(stderr = `Ui) ?(success_exits = [0]) ?post_exec ?k cmd
    =
    match cmd.cmd_tool with
    | Miss (tool, e) -> m.m.feedback (`Miss_tool (tool, e))
    | Tool tool ->
        let id = new_op_id m and created = timestamp m in
        let env, relevant_env = spawn_env m tool env in
        let cwd = match cwd with None -> m.m.cwd | Some d -> d in
        let k = match k with
        | None -> fun o -> ()
        | Some k ->
            fun o -> match Op.Spawn.exit (Op.Spawn.get o) with
            | Some (`Exited code) -> k code
            | _ -> assert false
        in
        let o =
          Op.Spawn.v_op
            ~id ~group:m.c.group ~created ~reads ~writes ?post_exec ~k ~stamp
            ~env ~relevant_env ~cwd ~stdin ~stdout ~stderr ~success_exits
            tool.tool_file cmd.cmd_args
        in
        add_op_and_stir m o

  module Fut = struct
    type memo = t
    type 'a t = 'a Futs.fut
    type 'a set = 'a Futs.fut_set
    let create m = Futs.fut m.m.futs
    let value = Futs.fut_value
    let set = Futs.fut_set
    let wait = Futs.fut_wait
  end
end

(*---------------------------------------------------------------------------
   Copyright (c) 2018 The b0 programmers

   Permission to use, copy, modify, and/or distribute this software for any
   purpose with or without fee is hereby granted, provided that the above
   copyright notice and this permission notice appear in all copies.

   THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
   WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
   MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
   ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
   WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
   ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
   OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
  ---------------------------------------------------------------------------*)
