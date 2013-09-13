%%
%% Copyright 2013 Joaquim Rocha
%% 
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%

-module(chair).

-include("chair.hrl").

-define(SERVER, {local, ?MODULE}).
-define(ACCEPT_HEADER, {"Accept", "application/json"}).
-define(CONTENT_TYPE_HEADER, {"Content-Type", "application/json"}).

-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% ====================================================================
%% API functions
%% ====================================================================
-export([start_link/0]).
-export([config_db/4, get_dbs/0]).
-export([get_info/1, get_uuid/1, get_uuids/2]).
-export([get_doc/2, insert_doc/2, update_doc/2, delete_doc/2]).

start_link() ->
	gen_server:start_link(?SERVER, ?MODULE, [], []).

config_db(DB, Host, Port, DBName) when is_atom(DB) andalso is_integer(Port) ->
	HostURL = "http://" ++ Host ++ ":" ++ integer_to_list(Port) ++ "/",
	DBURL = HostURL ++ DBName ++ "/",
	Config = #db_config{host=Host, 
						port=Port, 
						name=DBName, 
						host_url=HostURL,
						db_url=DBURL},
	gen_server:call(?MODULE, {config_db, DB, Config}).

get_dbs() ->
	gen_server:call(?MODULE, {get_dbs}).

get_info(DB) when is_atom(DB) ->
	case get_config(DB) of
		{ok, Config} -> 
			case execute_get(Config#db_config.host_url) of
				{ok, 200, Body} -> 
					Response = jsondoc:decode(Body),
					{ok, Response};
				{error, Error} -> {error, Error}
			end;
		error -> {error, db_not_found}
	end.

get_uuid(DB) when is_atom(DB) ->
	get_uuids(DB, 1).

get_uuids(DB, Count) when is_atom(DB) andalso is_integer(Count) andalso Count > 0 ->
	case get_config(DB) of
		{ok, Config} -> 
			Query = string:concat("_uuids?count=", integer_to_list(Count)),
			Url = string:concat(Config#db_config.host_url, Query),
			case execute_get(Url) of
				{ok, 200, Body} -> 
					Doc = jsondoc:decode(Body),
					UUIDs = jsondoc:get_value(<<"uuids">>, Doc),
					{ok, UUIDs};
				{error, Error} -> {error, Error}
			end;
		error -> {error, db_not_found}
	end.

get_doc(DB, ID) when is_atom(DB) and is_list(ID) ->
	case get_config(DB) of
		{ok, Config} -> 
			Url = string:concat(Config#db_config.db_url, ID),
			case execute_get(Url) of
				{ok, 200, Body} -> 
					Response = jsondoc:decode(Body),
					{ok, Response};
				{ok, _Status, Body} -> proccess_db_error(Body);						
				{error, Error} -> {error, Error}
			end;
		error -> {error, db_not_found}
	end;
get_doc(DB, ID) when is_atom(DB) and is_binary(ID) ->
	get_doc(DB, binary_to_list(ID)).

insert_doc(DB, Doc) when is_atom(DB) andalso is_tuple(Doc) andalso tuple_size(Doc) == 1 ->
	case get_config(DB) of
		{ok, Config} -> 
			Data = jsondoc:encode(Doc),
			case execute_post(Config#db_config.db_url, Data) of
				{ok, 201, Body} -> proccess_response_doc(Doc, Body);
				{ok, 202, Body} -> proccess_response_doc(Doc, Body);			
				{ok, _Status, Body} -> proccess_db_error(Body);						
				{error, Error} -> {error, Error}
			end;
		error -> {error, db_not_found}
	end.

update_doc(DB, Doc) when is_atom(DB) andalso is_tuple(Doc) andalso tuple_size(Doc) == 1 ->
	case get_config(DB) of
		{ok, Config} -> 
			ID = jsondoc:get_value(<<"_id">>, Doc),
			Url = string:concat(Config#db_config.db_url, binary_to_list(ID)),
			Data = jsondoc:encode(Doc),
			case execute_put(Url, Data) of
				{ok, 201, Body} -> proccess_response_doc(Doc, Body);
				{ok, 202, Body} -> proccess_response_doc(Doc, Body);			
				{ok, _Status, Body} -> proccess_db_error(Body);						
				{error, Error} -> {error, Error}
			end;
		error -> {error, db_not_found}
	end.

delete_doc(DB, Doc) when is_atom(DB) andalso is_tuple(Doc) andalso tuple_size(Doc) == 1 ->
	case get_config(DB) of
		{ok, Config} -> 
			ID = jsondoc:get_value(<<"_id">>, Doc),
			Rev = jsondoc:get_value(<<"_rev">>, Doc),
			URLDoc = string:concat(Config#db_config.db_url, binary_to_list(ID)),
			Query = string:concat("?rev=", binary_to_list(Rev)),
			Url = string:concat(URLDoc, Query),
			case execute_delete(Url) of
				{ok, 200, Body} -> proccess_delete(Body);
				{ok, 202, Body} -> proccess_delete(Body);			
				{ok, _Status, Body} -> proccess_db_error(Body);						
				{error, Error} -> {error, Error}
			end;
		error -> {error, db_not_found}
	end.

%% ====================================================================
%% Behavioural functions 
%% ====================================================================
-record(state, {databases}).

%% init
init([]) ->
	process_flag(trap_exit, true),	
	error_logger:info_msg("~p starting on [~p]...\n", [?MODULE, self()]),	
    {ok, #state{databases=dict:new()}}.

%% handle_call
handle_call({get_config, DB}, _From, State=#state{databases=DBs}) ->
	Reply = dict:find(DB, DBs),
	{reply, Reply, State};

handle_call({get_dbs}, _From, State=#state{databases=DBs}) ->
    Reply = dict:fetch_keys(DBs),
    {reply, Reply, State};

handle_call({config_db, DB, Config}, _From, State=#state{databases=DBs}) ->
    NewDBs=dict:store(DB, Config, DBs),
    {reply, ok, State#state{databases=NewDBs}}.

%% handle_cast
handle_cast(Msg, State) ->
	error_logger:info_msg("handle_cast(~p)\n", [Msg]),
    {noreply, State}.

%% handle_info
handle_info(Info, State) ->
	error_logger:info_msg("handle_info(~p)\n", [Info]),
    {noreply, State}.

%% terminate
terminate(_Reason, _State) ->
    ok.

%% code_change
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ====================================================================
%% Internal functions
%% ====================================================================

get_config(DB) ->
	gen_server:call(?MODULE, {get_config, DB}).

execute_get(Url) ->
	execute(Url, get).
	
execute_post(Url, Data) -> 
	execute(Url, post, Data).

execute_put(Url, Data) -> 
	execute(Url, put, Data).

execute_delete(Url) -> 
	execute(Url, delete).

execute(Url, Method) ->
	Response = ibrowse:send_req(Url, [?ACCEPT_HEADER], Method),
	response(Response).
	
execute(Url, Method, Body) ->
	Response = ibrowse:send_req(Url, [?ACCEPT_HEADER, ?CONTENT_TYPE_HEADER], Method, Body),
	response(Response).

response({ok, Status, _Headers, Body}) -> {ok, list_to_integer(Status), Body};
response({error, Error}) -> {error, Error}.

proccess_response_doc(Doc, Body) ->
	Response = jsondoc:decode(Body),
	Rev = jsondoc:get_value(<<"rev">>, Response),
	Doc1 = jsondoc:set_value(Doc, <<"_rev">>, Rev),
	{ok, Doc1}.

proccess_db_error(Body) ->
	Response = jsondoc:decode(Body),
	{db_error, Response}.

proccess_delete(Body) ->
	Response = jsondoc:decode(Body),
	Rev = jsondoc:get_value(<<"rev">>, Response),
	Doc = jsondoc:new(),
	Doc1 = jsondoc:set_value(Doc, <<"_rev">>, Rev),
	{ok, Doc1}.