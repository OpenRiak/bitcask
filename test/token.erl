%% -------------------------------------------------------------------
%%
%% Copyright (c) 2012-2017 Basho Technologies, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% This is heavily modified from the original:
%%  File        : token.erl
%%  Author      : Ulf Norell
%%  Description :
%%  Created     : 20 Mar 2012 by Ulf Norell
%%
%% It maintains the API but little else.
%% TODO: Make it help in tidying things up, or make it go away!
%%
%% There's probably a valid use case for some manner of stateful service for
%% tests, including some management of the forest of directories the tests
%% leave behind, but that's a battle for another day.
%%
-module(token).

-export([next_name/0, get_name/0, stop/0]).

-define(SERVICE, test_token_service).

-record(state, {
    int  = 0    :: non_neg_integer(),
    name = []   :: string()
}).

next_name() ->
    call(next).

get_name() ->
    call(get).

stop() ->
    call(stop).

call(Msg) ->
    case whereis(?SERVICE) of
        undefined ->
            start(),
            timer:sleep(1),
            call(Msg);
        Pid ->
            Ref = erlang:make_ref(),
            Pid ! {Msg, Ref, erlang:self()},
            receive
                {Ref, Result} ->
                    Result
            after
                1000 ->
                    {error, timeout}
            end
    end.

start() ->
    erlang:register(?SERVICE, erlang:spawn(fun init/0)).

init() ->
    loop(next_state(#state{})).

loop(State) ->
    receive
        {next, Tag, Pid} ->
            NewState = next_state(State),
            Pid ! {Tag, NewState#state.name},
            loop(NewState);
        {get, Tag, Pid} ->
            Pid ! {Tag, State#state.name},
            loop(State);
        {stop, Tag, Pid} ->
            Pid ! {Tag, ok},
            %% Don't really stop, but maintain the API behavior.
            loop(next_state(State))
    end.

next_state(#state{int = Cur} = State) ->
    {A, B, C} = os:timestamp(),
    Cand = ((A bsl 40) + (B bsl 20) + C),
    %% Like erlang:now/0, without the serialization and deprecation warnings.
    Next = if
        Cand > Cur ->
            Cand;
        true ->
            (Cur + 1)
    end,
    State#state{int = Next, name = erlang:integer_to_list(Next)}.
