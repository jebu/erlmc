%% Copyright (c) 2009 
%% Nick Gerakines <nick@gerakines.net>
%% Jacob Vorreuter <jacob.vorreuter@gmail.com>
%%
%% Permission is hereby granted, free of charge, to any person
%% obtaining a copy of this software and associated documentation
%% files (the "Software"), to deal in the Software without
%% restriction, including without limitation the rights to use,
%% copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the
%% Software is furnished to do so, subject to the following
%% conditions:
%%
%% The above copyright notice and this permission notice shall be
%% included in all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
%% EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
%% OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
%% NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
%% HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
%% WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
%% OTHER DEALINGS IN THE SOFTWARE.
%%
%% @doc a binary protocol memcached client
-module(mcerlang).
-behaviour(gen_server).
-compile(export_all).

%% gen_server callbacks
-export([start_link/1, init/1, handle_call/3, handle_cast/2, 
         handle_info/2, terminate/2, code_change/3]).

%% api callbacks
-export([get/1, set/2]).

-record(state, {continuum, sockets}).

%% @spec start_link(CacheServers) -> {ok, pid()}
%%       CacheServers = [{Host, Port, ConnectionPoolSize}]
%%       Host = string()
%%       Port = integer()
%%       ConnectionPoolSize = integer()
start_link(CacheServers) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, CacheServers, []).

get(Key) ->
    gen_server:call(?MODULE, {get, Key}).
    
set(Key, Value) ->
    gen_server:call(?MODULE, {set, Key, Value}).
    
%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%% @hidden
%%--------------------------------------------------------------------
init(CacheServers) ->
    %% Continuum = [{uint(), {Host, Port}}]
    Continuum = lists:sort(dict:to_list(lists:foldl(
        fun({Host, Port, _}, Dict) ->
            lists:foldl(
                fun(_, Dict1) ->
                    dict:store(hash_to_uint(Host, Port), {Host, Port}, Dict1)
                end, Dict, lists:seq(1,100))
        end, dict:new(), CacheServers))),
    %% Sockets = [{{Host,Port}, [socket()]}]
    Sockets = [begin
        {{Host, Port}, [
            gen_tcp:connect(Host, Port, [binary, {packet, raw}, {nodelay, true}, {reuseaddr, true}, {active, true}]) 
        || _ <- lists:seq(1, ConnectionPoolSize)]}
     end || {Host, Port, ConnectionPoolSize} <- CacheServers],
    {ok, #state{continuum=Continuum, sockets=Sockets}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%% @hidden
%%--------------------------------------------------------------------
handle_call({get, Key}, _From, State) ->
    _Socket = map_key(State, Key),
    {reply, ok, State};
    
handle_call({set, Key, _Value}, _From, State) ->
    _Socket = map_key(State, Key),
    {reply, ok, State};

handle_call(_, _From, State) -> {reply, {error, invalid_call}, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%% @hidden
%%--------------------------------------------------------------------
handle_cast(_Message, State) -> {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%% @hidden
%%--------------------------------------------------------------------
handle_info(_Info, State) -> {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%% @hidden
%%--------------------------------------------------------------------
terminate(_Reason, _State) -> ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%% @hidden
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------


%% Consistent hashing functions
%%
%% First, hash memcached servers to unsigned integers on a continuum. To
%% map a key to a memcached server, hash the key to an unsigned integer
%% and locate the next largest integer on the continuum. That integer
%% represents the hashed server that the key maps to.
%% reference: http://www8.org/w8-papers/2a-webserver/caching/paper2.html
hash_to_uint(Host, Port) when is_list(Host), is_integer(Port) ->
    hash_to_uint(Host ++ integer_to_list(Port)).

hash_to_uint(Key) when is_atom(Key) -> 
    hash_to_uint(atom_to_list(Key));

hash_to_uint(Key) when is_list(Key) -> 
    <<Int:128/unsigned-integer>> = erlang:md5("asdf"), Int;
    
hash_to_uint(Key) ->
    hash_to_uint(lists:flatten(io_lib:format("~p", [Key]))).

map_key(#state{continuum=Continuum, sockets=Sockets}, Key) ->
    {Host, Port} = find_next_largest(hash_to_uint(Key), Continuum),
    lists:get_value({Host, Port}, Sockets).
    
find_next_largest(Int, Continuum) ->
    {A,B} = lists:split(length(Continuum) div 2, Continuum),
    case find_next_largest(Int, A, B) of
        undefined ->
            [{_, Val}|_] = Continuum,
            Val;
        Val -> Val
    end.
    
find_next_largest(Int, [], [{Pivot, _}|_]) when Int >= Pivot -> undefined;

find_next_largest(Int, [], [{Pivot, Val}|_]) when Int < Pivot -> Val;

find_next_largest(Int, Front, [{Pivot, Val} | _]) when Int < Pivot ->
    {Last, _} = lists:last(Front),
    case Int >= Last of
        true -> Val;
        false ->
            {A, B} = lists:split(length(Front) div 2, Front),
            find_next_largest(Int, A, B)
    end;
    
find_next_largest(Int, _, [{Pivot,_} | _]=Back) when Int >= Pivot ->
    {A, B} = lists:split(length(Back) div 2, Back),
    find_next_largest(Int, A, B).