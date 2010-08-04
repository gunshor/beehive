%%% beehive_bee_object.erl
%% @author Ari Lerner <arilerner@mac.com>
%% @copyright 07/23/10 Ari Lerner <arilerner@mac.com>
%% @doc 
-module (beehive_bee_object).
-include_lib("kernel/include/file.hrl").
-include ("beehive.hrl").
-include ("common.hrl").

-export ([
  init/0,
  % Actions
  clone/1,clone/2,
  bundle/1,bundle/2,
  mount/2, mount/3,
  start/3, start/4,
  stop/2, stop/3,
  have_bee/1,
  info/1,
  cleanup/1,
  ls/1
]).

% Transportation
-export ([
  send_bee_object/2,
  get_bee_object/2,
  save_bee_object/2
]).


-define (DEBUG, false).
-define (DEBUG_PRINT (Args), fun() -> 
  case ?DEBUG of
    true -> erlang:display(Args);
    false -> ok
  end
end()).

-define (BEEHIVE_BEE_OBJECT_INFO_TABLE, 'beehive_bee_object_info').
-define (RUNNING_BEES_TABLE, 'running_bees_table').

% Initialize included bee_tpes
init() ->
  TableOpts = [set, named_table, public],
  case catch ets:info(?BEEHIVE_BEE_OBJECT_INFO_TABLE) of
    undefined -> ets:new(?BEEHIVE_BEE_OBJECT_INFO_TABLE, TableOpts);
    _ -> ok
  end,
  case catch ets:info(?RUNNING_BEES_TABLE) of
    undefined -> ets:new(?RUNNING_BEES_TABLE, TableOpts);
    _ -> ok
  end,
  % Ewww
  Dir =?BH_ROOT,
  beehive_bee_object_config:read(filename:join([Dir, "etc", "app_templates"])).

% List the bees in the directory
ls(BeeDir) ->
  lists:map(fun(Filepath) ->
    Filename = filename:basename(Filepath),
    string:sub_string(Filename, 1, length(Filename) - length(".bee"))
  end, filelib:wildcard(filename:join([BeeDir, "*.bee"]))).

% Create a new object from a directory or from a url
% This will clone the repository and ensure that the given 
% revision matches the actual revision of the repository
clone(E) -> clone(E, undefined).
clone(GivenProplist, From) when is_list(GivenProplist) ->
  BeeObject = from_proplists(GivenProplist),
  clone(BeeObject, From);
  
clone(#bee_object{type=Type, bundle_dir=BundleDir, revision=Rev}=BeeObject, From) when is_record(BeeObject, bee_object) ->  
  AfterClone = case beehive_bee_object_config:get_or_default(clone, Type) of
    {error, _} = T -> throw(T);
    Str2 -> Str2
  end,
  % Run before, if it needs to run
  run_hook_action(pre, BeeObject, From),
  case ensure_repos_exists(BeeObject, From) of
    {error, _Reason} = T2 -> 
      ?DEBUG_PRINT({error, ensure_repos_exists, T2}),
      T2;
    Out ->
      case Rev of
        undefined -> ok;
        _ -> ensure_repos_is_current_repos(BeeObject)
      end,
      TDude = run_in_directory_with_file(BeeObject, From, BundleDir, AfterClone),
      ?DEBUG_PRINT({run_in_directory_with_file, TDude, Out}),
      run_hook_action(post, BeeObject, From),
      Out
  end.

% Squash the bee object
% This will clone an object based on a given type and a bee_type 
% configuration file
% It will run the configuration file code first and then
% bundle it using a temp file
bundle(E) -> bundle(E, undefined).

bundle(Proplists, From) when is_list(Proplists) ->  
  BeeObject = from_proplists(Proplists),
  bundle(BeeObject, From);

% Take a url and clone/1 it and then bundle the directory
% based on the configuration directive
bundle(#bee_object{type = Type, bundle_dir = BundleDir} = BeeObject, From) when is_record(BeeObject, bee_object) ->  
  case clone(BeeObject, From) of
    {error, _} = T -> T;
    _E ->
      run_hook_action(pre, BeeObject, From),
      BeforeBundle = case beehive_bee_object_config:get_or_default(bundle, Type) of
        {error, _} = T -> throw(T);
        Str2 -> Str2
      end,
      
      % Run the bundle pre config first, then the bundle command
      case run_in_directory_with_file(BeeObject, From, BundleDir, BeforeBundle) of
        {error, _} = T2 -> T2;
        _BeforeActionOut -> 
          OriginalDir = file:get_cwd(),
          SquashCmd = proplists:get_value(bundle, config_props()),
          Proplist = to_proplist(BeeObject),
          Str = template_command_string(SquashCmd, Proplist),
          
          Out = try
            c:cd(BundleDir),
            cmd(Str, Proplist, From)
          after
            c:cd(OriginalDir)
          end,
          
          write_info_about_bee(BeeObject),
          run_hook_action(post, BeeObject, From),
          Out
      end
  end.

write_info_about_bee(#bee_object{
                        bee_file = BeeFile, 
                        meta_file = MetaFile, 
                        name = Name} = BeeObject) ->
  % Write the meta data
  {ok, Fileinfo} = file:read_file_info(BeeFile),
  {ok, CheckedRev} = get_current_sha(BeeObject),
  Info =  [
            {revision, CheckedRev}, {size, Fileinfo#file_info.size}, 
            {created_at, calendar:datetime_to_gregorian_seconds(Fileinfo#file_info.ctime)}
            |to_proplist(BeeObject)
          ],
  
  ets:insert(?BEEHIVE_BEE_OBJECT_INFO_TABLE, [{Name, Info}]),
  % Write it to a file, for sure... debatable
  {ok, Io} = file:open(MetaFile, [write]),
  file:write(Io, term_to_binary(Info)).

% Mount the bee
mount(Type, Name) -> mount(Type, Name, undefined).
mount(Type, Name, From) ->
  AfterMountScript = case beehive_bee_object_config:get_or_default(mount, Type) of
    {error, _} = T -> throw(T);
    Str2 -> Str2
  end,
  BeeFile = find_bee_file(Name),
  MountRootDir = config:search_for_application_value(run_dir),
  MountDir = filename:join([MountRootDir, Name]),
  MountCmd = proplists:get_value(mount, config_props()),
  
  BeeObject = from_proplists([{name, Name}, {type, Type}, {bee_file, BeeFile}, 
                              {run_dir, MountDir}, {bundle_dir, filename:dirname(BeeFile)}
                            ]),
  
  run_hook_action(pre, BeeObject, From),
  Str = template_command_string(MountCmd, to_proplist(BeeObject)),
  ?DEBUG_PRINT({run_dir, filename:join([MountDir, "dummy_dir"])}),
  ensure_directory_exists(filename:join([MountDir, "dummy_dir"])),
  T2 = run_command_in_directory(Str, MountDir, From, BeeObject),
  run_in_directory_with_file(BeeObject, From, MountDir, AfterMountScript),
  run_hook_action(post, BeeObject, From),
  T2.

% Start the beefile
start(Type, Name, Port) -> start(Type, Name, Port, undefined).
start(Type, Name, Port, From) ->
  StartScript = case beehive_bee_object_config:get_or_default(start, Type) of
    {error, _} = T -> throw(T);
    Str2 -> Str2
  end,
  BeeDir = find_mounted_bee(Name),
  FoundBeeObject = find_bee(Name),
  BeeObject = FoundBeeObject#bee_object{port = Port, run_dir = BeeDir},
  % BeeObject = from_proplists([{name, Name}, {type, Type}, {bee_file, BeeFile}, {run_dir, BeeDir}, {port, Port}]),
  Pid = spawn_link(fun() ->
    {ok, ScriptFilename, ScriptIo} = temp_file(),
    file:write(ScriptIo, StartScript),
    try
      {ok, PidFilename, _PidIo} = temp_file(),
      {Pid, Ref, Tag} = async_command("/bin/sh", [ScriptFilename], [{pidfile, PidFilename}|to_proplist(BeeObject)], From),
      timer:sleep(500),
      OsPid = case file:read_file(PidFilename) of
        {ok, Bin} ->
          IntList = chop(erlang:binary_to_list(Bin)),
          list_to_integer(IntList);
        _ -> Pid
      end,
      file:delete(PidFilename),
      file:delete(ScriptFilename),
      cmd_receive(Pid, [], From, fun(Msg) ->
        case Msg of
          {'DOWN', Ref, process, Pid, {Tag, Data}} -> Data;
          {'DOWN', Ref, process, Pid, Reason} -> send_to(From, {stopped, {Name, Reason}});
          {stop} ->
            case OsPid of
              IntPid when is_integer(IntPid) andalso IntPid > 1 ->
                os:cmd(lists:flatten(["kill ", integer_to_list(OsPid)]));
              _ -> ok
            end;
          _ -> ok
        end
      end)
    after
      % Just in case
      file:delete(ScriptFilename) 
    end
  end),
  write_info_about_bee(BeeObject#bee_object{pid = Pid}),
  Pid.

stop(Type, Name) -> stop(Type, Name, undefined).
stop(_Type, Name, _From) ->
  case find_bee(Name) of
    #bee_object{pid = Pid} = BeeObject when is_record(BeeObject, bee_object) ->      
      Pid ! {stop},
      timer:sleep(500);
    _ -> {error, not_running}
  end.

% Delete the bee and the meta data
cleanup(Name) ->
  case catch find_mounted_bee(Name) of
    {error, _} -> ok;
    MountDir -> rm_rf(MountDir)
  end,
  % In this case, beefile is name
  case catch find_bee_file(Name) of
    {error, _} -> ok;
    Beefile ->
      file:delete(lists:flatten([Beefile, ".meta"])),
      file:delete(Beefile)
  end.

% Get information about the Beefile  
info(Name) when is_list(Name) ->
  case ets:lookup(?BEEHIVE_BEE_OBJECT_INFO_TABLE, Name) of
    [{Name, Props}|_Rest] -> Props;
    _ ->
      case catch find_bee_file(Name) of
        {error, not_found} -> {error, not_found};
        Beefile when is_record(Beefile, bee_object) -> info(Beefile)
      end
  end;
info(#bee_object{meta_file = MetaFile, name = Name} = BeeObject) when is_record(BeeObject, bee_object) ->
  case file:read_file(MetaFile) of
    {ok, Bin} ->
      Out = binary_to_term(Bin),
      ets:insert(?BEEHIVE_BEE_OBJECT_INFO_TABLE, [{Name, Out}]),
      Out;
    _FileNotPresentError -> {error, not_found}
  end.

have_bee(Name) ->
  case catch find_bee_file(Name) of
    {error, not_found} -> false;
    _File -> true
  end.

% Send to the node
send_bee_object(ToNode, #bee_object{bee_file = BeeFile} = BeeObject) when is_record(BeeObject, bee_object) ->
  case rpc:call(ToNode, code, is_loaded, [?MODULE]) of
    {file, _} -> ok;
    _ ->
      {Mod, Bin, File} = code:get_object_code(?MODULE), 
      rpc:call(ToNode, code, load_binary, [Mod, File, Bin])
  end,
  {ok, B} = prim_file:read_file(BeeFile),
  rpc:call(ToNode, ?MODULE, save_bee_object, [B, BeeObject]).

% Get from a node
get_bee_object(FromNode, Name) ->
  BeeObject = find_bee(Name),
  case rpc:call(FromNode, ?MODULE, send_bee_object, [node(), BeeObject#bee_object{name = Name}]) of
    {badrpc, Err} ->
      io:format("ERROR SAVING ~p to ~p because: ~p~n", [Name, BeeObject, Err]);
    E -> 
      E
  end.

% Save
% Save the file contents to
save_bee_object(Contents, #bee_object{bee_file = To} = BeeObject) ->
  FullFilePath = case filelib:is_dir(To) of
    true -> To;
    false ->
      FullPath = filename:join([filename:absname(""), To]),
      ensure_directory_exists(FullPath),
      FullPath
  end,
  prim_file:write_file(FullFilePath, Contents),
  write_info_about_bee(BeeObject),
  validate_bee_object(BeeObject).

%%%%%%%%%%%%%%%%%
% HELPERS
%%%%%%%%%%%%%%%%%
run_hook_action(pre, BeeObject, From) -> run_hook_action_str(BeeObject#bee_object.pre, BeeObject, From);
run_hook_action(post, BeeObject, From) -> run_hook_action_str(BeeObject#bee_object.post, BeeObject, From).

run_hook_action_str(CmdStr, #bee_object{bundle_dir = BundleDir} = BeeObject, From) ->
  case CmdStr of
    undefined -> ok;
    _ ->
      case run_in_directory_with_file(BeeObject, From, BundleDir, CmdStr) of
        {error, _} = T -> throw({hook_error, T});
        E -> E
      end
  end.
% Check the url from the type
extract_vcs_type(undefined, Url) when is_list(Url) ->
  case check_type_from_the_url_string(Url, ["git://", "svn://"]) of
    "git://" -> git;
    "svn://" -> svn;
    unknown -> throw({error, unknown_vcs_type})
  end;
extract_vcs_type(VcsType, _Url) when is_atom(VcsType) -> VcsType;
extract_vcs_type(_, _) -> unknown.

% Attempt to extract the type of the vcs from the url
check_type_from_the_url_string(_Str, []) -> unknown;
check_type_from_the_url_string(Str, [H|Rest]) ->
  case string:str(Str, H) of
    0 -> check_type_from_the_url_string(Str, Rest);
    _ -> H
  end.

% Ensure the repos exists with the current revision clone
ensure_repos_exists(#bee_object{bundle_dir = BundleDir} = BeeObject, From) -> 
  ensure_directory_exists(BundleDir),
  case filelib:is_dir(BundleDir) of
    true -> update_repos(BeeObject, From);
    false -> clone_repos(BeeObject, From)
  end.
  
% Checkout the repos using the config method
clone_repos(BeeObject, From)   -> run_action_in_directory(clone, BeeObject, From).
update_repos(BeeObject, From)  -> run_action_in_directory(update, BeeObject, From).

ensure_repos_is_current_repos(#bee_object{revision = Rev} = BeeObject) when is_record(BeeObject, bee_object) ->
  ?DEBUG_PRINT({updating_to_revision, Rev, get_current_sha(BeeObject)}),
  case get_current_sha(BeeObject) of
    {ok, CurrentCheckedRevision} ->      
      case CurrentCheckedRevision =:= Rev of
        true -> ok;
        false ->  run_action_in_directory(checkout, BeeObject, undefined)
      end;
    {error, _Lines} = T -> T
  end.

% Get the sha of the bee
get_current_sha(BeeObject) ->
  case run_action_in_directory(check_revision, BeeObject, undefined) of
    {ok, [CurrentCheckedRevision|_Output]} -> 
      {ok, chop(CurrentCheckedRevision)};
    T -> {error, T}
  end.


% Run in the directory given in the proplists
% Action
% Props
run_action_in_directory(Action, #bee_object{vcs_type = VcsType, bundle_dir = BundleDir} = BeeObject, From) ->
  ?DEBUG_PRINT({run_action_in_directory, action, Action}),
  case proplists:get_value(Action, config_props(VcsType)) of
    undefined -> throw({error, action_not_defined, Action});
    FoundAction -> 
      Str = template_command_string(FoundAction, to_proplist(BeeObject)),
      run_command_in_directory(Str, BundleDir, From, BeeObject)
  end.
  
% Run a command in the directory
run_command_in_directory(Cmd, Dir, From, BeeObject) ->
  {ok, OriginalDir} = file:get_cwd(),
  try
    c:cd(Dir),
    cmd(Cmd, to_proplist(BeeObject), From)
  after
    c:cd(OriginalDir)
  end.

% Run file
run_in_directory_with_file(_BeeObject, _From, _Dir, undefined) -> ok;
run_in_directory_with_file(BeeObject, From, Dir, Str) ->
  {ok, Filename, Io} = temp_file(),
  RealStr = case string:str(Str, "#!/bin/") of
    0 -> lists:flatten(["#!/bin/sh -e\n", Str]);
    _ -> Str
  end,
  file:write(Io, RealStr),
  try
    run_command_in_directory(lists:flatten(["/bin/sh ", Filename]), Dir, From, BeeObject)
  after
    file:delete(Filename)
  end.

% Synchronus command
cmd(Str, Envs, From) ->
  [Exec|Rest] = string:tokens(Str, " "),
  case catch cmd(Exec, Rest, Envs, From) of
    {'EXIT', T} -> {error, T};
    E -> E
  end.

cmd(Cmd, Args, Envs, From) ->
  {Pid, Ref, Tag} = async_command(Cmd, Args, Envs, From),
  receive
    {'DOWN', Ref, process, Pid, {Tag, Data}} -> Data;
    {'DOWN', Ref, process, Pid, Reason} -> exit(Reason)
  end.

async_command(Cmd, Args, Envs, From) ->
  Tag = make_ref(), 
  {Pid, Ref} = erlang:spawn_monitor(fun() ->
    Rv = cmd_sync(Cmd, Args, build_envs(Envs), From),
    exit({Tag, Rv})
  end),
  {Pid, Ref, Tag}.

cmd_sync(Cmd, Args, Envs, From) ->
  P = open_port({spawn_executable, os:find_executable(Cmd)}, [
    binary, stderr_to_stdout, use_stdio, exit_status, stream, eof, {args, Args}, {env, Envs}
    ]),
  cmd_receive(P, [], From, undefined).

cmd_receive(Port, Acc, From, Fun) ->
  receive
    {Port, {data, Data}}      -> 
      List = binary_to_list(Data),
      send_to(From, {data, List}),
      run_function(Fun, {data, Data}),
      cmd_receive(Port, [List|Acc], From, Fun);
    {Port, {exit_status, 0}}  -> 
      send_to(From, closed),
      run_function(Fun, {exit_status, 0}),
      {ok, lists:reverse(Acc)};
    {Port, {exit_status, N}}  -> 
      send_to(From, {error, N}),
      run_function(Fun, {exit_status, N}),
      port_close(Port),
      {error, {N, lists:reverse(Acc)}};
    E ->
      run_function(Fun, E),
      cmd_receive(Port, Acc, From, Fun)
    after 5000 ->
      throw({timeout})
  end.

run_function(undefined, _) -> ok;
run_function(Fun, Msg) when is_function(Fun) -> Fun(Msg).
  
send_to(undefined, _Msg) -> ok;
send_to(From, Msg) ->
  From ! Msg.

% Ensure the parent directory exists
ensure_directory_exists(Dest) ->
  Dir = filename:dirname(Dest),
  file:make_dir(Dir).

% Pull off the config_props for the specific vcs
config_props(VcsType) ->
  case  proplists:get_value(VcsType, config_props()) of
    undefined -> throw({error, unknown_vcs_type});
    Props -> Props
  end.

config_props() ->
  Dir =?BH_ROOT,
  {ok, C} = file:consult(filename:join([Dir, "etc", "beehive_bee_object_config.conf"])),
  C.

% String things
template_command_string(Str, Props) when is_list(Props) -> mustache:render(Str, dict:from_list(Props)).
chop(ListofStrings) -> string:strip(ListofStrings, right, $\n).

from_proplists(Propslist) -> from_proplists(Propslist, #bee_object{}).
from_proplists([], BeeObject) -> validate_bee_object(BeeObject);
from_proplists([{name, V}|Rest], BeeObject) -> from_proplists(Rest, BeeObject#bee_object{name = V});
from_proplists([{branch, V}|Rest], BeeObject) -> from_proplists(Rest, BeeObject#bee_object{branch = V});
from_proplists([{revision, V}|Rest], BeeObject) -> from_proplists(Rest, BeeObject#bee_object{revision = V});
from_proplists([{vcs_type, V}|Rest], BeeObject) -> from_proplists(Rest, BeeObject#bee_object{vcs_type = V});
from_proplists([{url, V}|Rest], BeeObject) -> from_proplists(Rest, BeeObject#bee_object{url = V});
from_proplists([{type, V}|Rest], BeeObject) -> from_proplists(Rest, BeeObject#bee_object{type = V});
from_proplists([{run_dir, V}|Rest], BeeObject) -> from_proplists(Rest, BeeObject#bee_object{run_dir = V});
from_proplists([{bundle_dir, V}|Rest], BeeObject) -> from_proplists(Rest, BeeObject#bee_object{bundle_dir = V});
from_proplists([{bee_file, V}|Rest], BeeObject) -> from_proplists(Rest, BeeObject#bee_object{bee_file = V});
from_proplists([{meta_file, V}|Rest], BeeObject) -> from_proplists(Rest, BeeObject#bee_object{meta_file = V});
from_proplists([{port,V}|Rest], BeeObject) -> from_proplists(Rest, BeeObject#bee_object{port = V});
from_proplists([{pre,V}|Rest], BeeObject) -> from_proplists(Rest, BeeObject#bee_object{pre = V});
from_proplists([{post,V}|Rest], BeeObject) -> from_proplists(Rest, BeeObject#bee_object{post = V});
from_proplists([{pid,V}|Rest], BeeObject) -> from_proplists(Rest, BeeObject#bee_object{pid = V});
from_proplists([{Other,V}|Rest], BeeObject) -> 
  CurrentEnv = case BeeObject#bee_object.env of
    undefined -> [];
    E -> E
  end,
  from_proplists(Rest, BeeObject#bee_object{env = [{Other,V}|CurrentEnv]}).

to_proplist(BeeObject) -> to_proplist(record_info(fields, bee_object), BeeObject, []).
to_proplist([], _BeeObject, Acc) -> Acc;
to_proplist([name|Rest], #bee_object{name = Name} = Bo, Acc) -> to_proplist(Rest, Bo, [{name, Name}|Acc]);
to_proplist([branch|Rest], #bee_object{branch = V} = Bo, Acc) -> to_proplist(Rest, Bo, [{branch, V}|Acc]);
to_proplist([revision|Rest], #bee_object{revision = V} = Bo, Acc) -> to_proplist(Rest, Bo, [{revision, V}|Acc]);
to_proplist([vcs_type|Rest], #bee_object{vcs_type = V} = Bo, Acc) -> to_proplist(Rest, Bo, [{vcs_type, V}|Acc]);
to_proplist([url|Rest], #bee_object{url = V} = Bo, Acc) -> to_proplist(Rest, Bo, [{url, V}|Acc]);
to_proplist([type|Rest], #bee_object{type = V} = Bo, Acc) -> to_proplist(Rest, Bo, [{type, V}|Acc]);
to_proplist([run_dir|Rest], #bee_object{run_dir = V} = Bo, Acc) -> to_proplist(Rest, Bo, [{run_dir, V}|Acc]);
to_proplist([bundle_dir|Rest], #bee_object{bundle_dir = V} = Bo, Acc) -> to_proplist(Rest, Bo, [{bundle_dir, V}|Acc]);
to_proplist([bee_file|Rest], #bee_object{bee_file = V} = Bo, Acc) -> to_proplist(Rest, Bo, [{bee_file, V}|Acc]);
to_proplist([meta_file|Rest], #bee_object{meta_file = V} = Bo, Acc) -> to_proplist(Rest, Bo, [{meta_file, V}|Acc]);
to_proplist([port|Rest], #bee_object{port = V} = Bo, Acc) -> to_proplist(Rest, Bo, [{port, V}|Acc]);
to_proplist([pre|Rest], #bee_object{pre = V} = Bo, Acc) -> to_proplist(Rest, Bo, [{pre, V}|Acc]);
to_proplist([post|Rest], #bee_object{post = V} = Bo, Acc) -> to_proplist(Rest, Bo, [{post, V}|Acc]);
to_proplist([pid|Rest], #bee_object{pid = V} = Bo, Acc) -> to_proplist(Rest, Bo, [{pid, V}|Acc]);
to_proplist([env|Rest], #bee_object{env = V} = Bo, Acc) -> to_proplist(Rest, Bo, lists:flatten([V|Acc]));
to_proplist([_H|Rest], BeeObject, Acc) -> to_proplist(Rest, BeeObject, Acc).

validate_bee_object(BeeObject) when is_record(BeeObject, bee_object) -> 
  validate_bee_object(record_info(fields, bee_object), BeeObject).
validate_bee_object([name|_Rest], #bee_object{name = undefined} = _BeeObject) -> throw({error, no_name_given});
validate_bee_object([bundle_dir|Rest], #bee_object{bundle_dir = undefined, name = Name} = BeeObject) -> 
  RootDir = config:search_for_application_value(bundle_dir),
  RealBundleDir = filename:join([RootDir, Name]),
  validate_bee_object(Rest, BeeObject#bee_object{bundle_dir = RealBundleDir});
validate_bee_object([run_dir|Rest], #bee_object{run_dir = undefined} = BeeObject) -> 
  validate_bee_object(Rest, BeeObject#bee_object{run_dir = config:search_for_application_value(run_dir)});
% Validate branch
validate_bee_object([branch|Rest], #bee_object{branch = undefined} = BeeObject) ->
  validate_bee_object(Rest, BeeObject#bee_object{branch = "master"});
% Validate the bee_file
validate_bee_object([bee_file|Rest], #bee_object{bee_file=undefined, name=Name} = BeeObject) ->  
  RootDir = config:search_for_application_value(bundle_dir),
  BeeFile = filename:join([RootDir, lists:flatten([Name, ".bee"])]),
  validate_bee_object(Rest, BeeObject#bee_object{bee_file = BeeFile});
validate_bee_object([meta_file|Rest], #bee_object{meta_file = undefined, bee_file = Bf} = BeeObject) ->
  validate_bee_object(Rest, BeeObject#bee_object{meta_file = lists:flatten([Bf, ".meta"])});
% TRy to extract the type
validate_bee_object([vcs_type|Rest], #bee_object{vcs_type=Type, url=Url} = BeeObject) ->
  FoundType = extract_vcs_type(Type, Url),
  validate_bee_object(Rest, BeeObject#bee_object{vcs_type = FoundType});
validate_bee_object([pid|Rest], #bee_object{pid = Pid} = BeeObject) when is_list(Pid) ->
  validate_bee_object(Rest, BeeObject#bee_object{pid = list_to_pid(Pid)});
validate_bee_object([], BeeObject) ->  BeeObject;
validate_bee_object([_H|Rest], BeeObject) -> validate_bee_object(Rest, BeeObject).

% Get temp_file
temp_file() ->
  Filename = test_server:temp_name(atom_to_list(?MODULE)),
  Filepath = filename:join(["/tmp", Filename]),
  {ok, Io} = file:open(Filepath, [write]),
  {ok, Filepath, Io}.

build_envs(Proplists) ->
  lists:flatten(lists:map(fun build_env/1, lists:filter(fun({K, V}) -> valid_env_prop(K, V) end, Proplists))).

build_env({env, V}) -> build_envs(V);
build_env({pid, V}) when is_pid(V) -> {"PID", erlang:pid_to_list(V)};
build_env({K,V}) -> {string:to_upper(to_list(K)), chop(to_list(V))}.

valid_env_prop(pre_action, _V) -> false;
valid_env_prop(before_clone, _V) -> false;
valid_env_prop(after_clone, _V) -> false;
valid_env_prop(post_action, _V) -> false;
valid_env_prop(from, _) -> false;
valid_env_prop(_, undefined) -> false;
valid_env_prop(_, _) -> true.

to_list(undefined) -> "";
to_list(Int) when is_integer(Int) -> erlang:integer_to_list(Int);
to_list(Atom) when is_atom(Atom) -> erlang:atom_to_list(Atom);
to_list(List) when is_list(List) -> List.

find_bee_file(Name) ->
  BundleDir = config:search_for_application_value(bundle_dir),
  BeeFile = filename:join([BundleDir, lists:flatten([Name, ".bee"])]),
  case filelib:is_file(BeeFile) of
    false -> throw({error, not_found});
    true -> BeeFile
  end.

find_bee(Name) -> from_proplists(info(Name)).

find_mounted_bee(Name) ->
  MountRootDir = config:search_for_application_value(run_dir),
  MountDir = filename:join([MountRootDir, Name]),
  case filelib:is_dir(MountDir) of
    false -> throw({error, not_found});
    true -> MountDir
  end.

% Cleanup a directory
rm_rf(Dir) -> 
  lists:foreach(fun(D) -> rm_rf(D) end, get_dirs(Dir)),
  lists:foreach(fun(File) ->
    file:delete(File)
  end, get_files(Dir)),
  % Now we can remove the empty directory
  file:del_dir(Dir),
  ok.

% Get directories
get_dirs(Dir) -> lists:filter(fun(X) -> filelib:is_dir(X) end, filelib:wildcard(filename:join([Dir, "*"]))).
get_files(Dir) -> lists:filter(fun(X) -> not filelib:is_dir(X) end, filelib:wildcard(filename:join([Dir, "*"]))).
