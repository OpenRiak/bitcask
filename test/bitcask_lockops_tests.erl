%% -------------------------------------------------------------------
%%
%% Copyright (c) 2018-2022 Workday, Inc.
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
-module(bitcask_lockops_tests).

-include_lib("eunit/include/eunit.hrl").
-include("bitcask.hrl").

-export([bitcask_locker_vm_main/1]).

lock_cannot_be_obtained_on_already_locked_file_within_same_os_process_test() ->
    Dir = bitcask:create_test_dir(),
    Filename = bitcask_lockops:lock_filename(write,Dir),
    ok = file_delete(Filename),
    ok = file:write_file(Filename, ""),
    {ok, _Lock} = bitcask_lockops:acquire(write, Dir),
    ?assertEqual(
       {error, locked},
       bitcask_lockops:acquire(write, Dir)
    ).

lock_can_be_obtained_on_already_locked_file_is_unlocked_test() ->
    Dir = bitcask:create_test_dir(),
    Filename = bitcask_lockops:lock_filename(write,Dir),
    ok = file_delete(Filename),
    ok = file:write_file(Filename, ""),
    {ok, Lock} = bitcask_lockops:acquire(write, Dir),
    bitcask_lockops:release(Lock),
    ?assertMatch(
       {ok, _},
       bitcask_lockops:acquire(write, Dir)
    ).

lock_cannot_be_obtained_on_already_locked_file_across_os_process_test() ->
    Dir = filename:absname(bitcask:create_test_dir()),
    %% start another erlang vm that will open the DB and obtain a write
    %% lock, then, when we try to obtain a write lock on the current vm
    %% it should fail.
    {?MODULE, _, TBeam} = code:get_object_code(?MODULE),
    {bitcask, _, BBeam} = code:get_object_code(bitcask),
    Tbin = filename:dirname(TBeam),
    Bbin = filename:dirname(BBeam),
    Erl = filename:join([code:root_dir(), "bin", "erl"]),
    Eval =
        Erl ++ " -pa " ++ Bbin ++ " -pa " ++ Tbin ++ " -noinput -noshell -eval"
        " 'bitcask_lockops_tests:bitcask_locker_vm_main(\"" ++ Dir ++ "\").'",
    % ?debugFmt("~nCOMMAND: ~ts", [Eval]),
    spawn_link(
        fun() ->
            Output = os:cmd(Eval),
            % To see this output you'll need to sleep after the 'assertMatch'
            ?debugFmt("~nOUTPUT: ~ts", [Output])
        end),
    timer:sleep(1000),
    DB = bitcask:open(Dir,[read_write]),
    ?assertMatch(
       {error,{error,locked}},
       bitcask:put(DB, <<"k">>, <<"v">>)
    ).

%% entry function for another vm to lock a bitcask DB
bitcask_locker_vm_main(Dir) ->
    case (catch bitcask:open(Dir, [read_write,{open_timeout,1000}])) of
        {error, Error} ->
            io:format("ERROR: ~0tp", [Error]);
        DB ->
            %% DB is locked on the first write operation
            ok = bitcask:put(DB, <<"k">>, <<"v">>),
            io:format("~0tp", [os:getpid()]),
            timer:sleep(3000),
            erlang:halt()
    end.

file_delete(Filename) ->
    case file:delete(Filename) of
        ok -> ok;
        {error,enoent} -> ok
    end.

