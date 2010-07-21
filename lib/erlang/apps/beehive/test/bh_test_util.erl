-module (bh_test_util).
-author("Ari Lerner <arilerner@mac.com>").
-compile(export_all).
-include ("beehive.hrl").

setup() ->
  setup([]).

setup(Proplist) when is_list(Proplist) ->
  Dir = filename:dirname(filename:dirname(code:which(?MODULE))),
  ConfigFile = filename:join([Dir, "test", "fixtures", "beehive.cfg"]),
  
  application:set_env(beehive, node_type, proplists:get_value(node_type, Proplist, test_type)),
  application:set_env(beehive, config_file, proplists:get_value(config_file, Proplist, ConfigFile)),
  application:set_env(beehive, beehive_home, proplists:get_value(node_type, Proplist, "/tmp/beehive/test")),
  application:set_env(beehive, database_dir, proplists:get_value(database_dir, Proplist, "/tmp/beehive/test/test_db")),
  
  % application:start(sasl),
  beehive:start([{beehive_db_srv, testing}]),
  
  beehive_db_srv:init_databases(),
  timer:sleep(200),
  % We don't need any error output here
  inets:start(),
  ok;
  
setup(Table) ->
  % beehive_db_srv:start_link(),
  % application:start(sasl),
  setup(),
  clear_table(Table),
  ok.

% get_url(Props) ->
%   Host = proplists:get_value(host, Props, "localhost"),
%   Port = proplists:get_value(port, Props, undefined),
%   Path = proplists:get_value(path, Props, "/"),
%   
%   UA = proplists:get_value(user_agent, Props, "Erlang-cli"),
%   
%   Url = case Port of
%     undefined -> lists:flatten(["http://", Host, Path]);
%     _ -> lists:flatten(["http://", Host, ":", integer_to_list(Port), Path])
%   end,
%   
%   case httpc:request(get, {Url, [{"User-Agent", UA}]}, [], []) of
%     {ok, {{_HttpVer, Code, _Msg}, _Headers, Body}} -> {ok, Code, Body};
%     {error, E} -> E
%   end.

fetch_url(Method, Props) ->
  Host    = proplists:get_value(host, Props, "localhost"),
  Port    = proplists:get_value(port, Props, undefined),
  Path    = proplists:get_value(path, Props, "/"),

  Headers = proplists:get_value(headers, Props, []),
  
  {ok, Sock} = gen_tcp:connect(Host, Port, [binary]),
  
  RequestLine = lists:flatten([string:to_upper(atom_to_list(Method)), " ", Path, " HTTP/1.0\r\n", 
                lists:map(fun({Key, Value}) ->
                  lists:flatten([string:to_upper(atom_to_list(Key)), ": ", Value, "\n"])
                end, Headers), "\r\n"]),
  gen_tcp:send(Sock, RequestLine),
  request(Sock, []).

request(Sock, Acc) ->
  receive
	  {tcp, Sock, Data} ->
      % Received data
      request(Sock, [binary_to_list(Data)|Acc]);
    {tcp_closed, Sock} ->
      parse_http_request(lists:flatten(lists:reverse(Acc)));
  	{tcp_error, Sock} ->
      {error, Sock};
  	_Else -> request(Sock, Acc)
  % If there is no activity for a while and the socket has not already closed, 
  % we'll assume that the connection is tired and should close, so we'll close it
  after 3000 ->
    {error, timeout}
  end.

parse_http_request(Acc) ->
  [Headers|Body] = string:tokens(Acc, "\r\n"),
  {ok, Headers, Body}.

teardown() ->
  application:set_env(beehive, beehive_home, "/tmp/beehive/test"),
  beehive:stop(),
  ok.
  
clear_table(Table) ->
  beehive_db_srv:delete_all(Table),
  ok.

start(Count)      -> start(Count, example_cluster_srv, 0, []).
start(Count, Mod) -> start(Count, Mod, 0, []).
start(Count, _Mod, Count, Acc) -> {ok, Acc};
start(Count, Mod, CurrentCount, Acc) ->
  Name = erlang:list_to_atom(lists:flatten(["node", erlang:integer_to_list(CurrentCount)])),
  Seed = case erlang:length(Acc) of
    0 -> undefined;
    _ -> whereis(erlang:hd(Acc))
  end,
  {ok, _NodePid} = Mod:start_named(Name, [{seed, Seed}]),
  start(Count, Mod, CurrentCount + 1, [Name|Acc]).
  
shutdown([]) -> ok;
shutdown([Pname|Rest]) -> 
  Pid = whereis(Pname),
  gen_cluster:cast(Pid, stop), 
  try unregister(Pname)
  catch _:_ -> ok
  end,
  shutdown(Rest).

context_run(Count, Fun) ->
  {ok, Nodes} = start(Count),
  Fun(),
  shutdown(Nodes).

% FIXTURE
dummy_app() ->
  Dir = filename:dirname(filename:dirname(code:which(?MODULE))),
  ReposDir = filename:join([Dir, "test", "fixtures", "dummy_srv"]),
  ReposUrl = lists:concat(["file://", ReposDir]),
  
  {ok, App} = case apps:find_by_name("test_app") of
    not_found ->
      AppC = #app{name = "test_app", url = ReposUrl},
      apps:create(AppC);
    App1 ->
      {ok, App1}
  end,
  App.

dummy_user() ->
  {ok, User} = case users:find_by_email("test@getbeehive.com") of
    not_found ->
      UserC = #user{email = "test@getbeehive.com", password="test"},
      users:create(UserC);
    U1 -> {ok, U1}
  end,
  User.

% Utils
delete_all(Table) ->
  Pluralized = erlang:list_to_atom(lists:append([erlang:atom_to_list(Table), "s"])),
  lists:map(fun(O) -> 
    Pluralized:delete(O) 
  end, Pluralized:all()).
  % beehive_db_srv:delete_all(Table).