%% -------------------------------------------------------------------
%%
%% Copyright (c) 2010-2017 Basho Technologies, Inc.
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

-record(bitcask_entry, {
    key         :: binary(),
    file_id     :: integer(),
    total_sz    :: integer(),
    offset      :: integer() | binary(),
    tstamp      :: integer()
}).

%% @type filestate().
-record(filestate, {
    mode            :: 'read_only' | 'read_write' | undefined,  % File open mode
    filename        :: string(),                  % Filename
    tstamp          :: integer() | undefined,     % Timestamp portion of filename
    fd              :: port() | undefined,        % File handle
    hintfd          :: port() | undefined,        % File handle for hints
    hintcrc = 0     :: integer(),                 % CRC-32 of current hint
    ofs             :: non_neg_integer() | undefined, % Current offset for writing
    l_ofs = 0       :: non_neg_integer(),   % Last offset written to data file
    l_hbytes = 0    :: non_neg_integer(),   % Last # bytes written to hint file
    l_hintcrc = 0   :: non_neg_integer()    % CRC-32 of current hint prior to last write
}).

-record(file_status, {
    filename        :: string(),
    fragmented      :: integer(),
    dead_bytes      :: integer(),
    total_bytes     :: integer(),
    oldest_tstamp   :: integer(),
    newest_tstamp   :: integer(),
    expiration_epoch :: non_neg_integer()
}).

-define(FMT(Str, Args), lists:flatten(io_lib:format(Str, Args))).

-define(TOMBSTONE_PREFIX, "bitcask_tombstone").
-define(TOMBSTONE0_STR, ?TOMBSTONE_PREFIX).
-define(TOMBSTONE0, <<?TOMBSTONE0_STR>>).
-define(TOMBSTONE1_STR, ?TOMBSTONE_PREFIX "1").
-define(TOMBSTONE1_BIN, <<?TOMBSTONE1_STR>>).
-define(TOMBSTONE2_STR, ?TOMBSTONE_PREFIX "2").
-define(TOMBSTONE2_BIN, <<?TOMBSTONE2_STR>>).
-define(TOMBSTONE0_SIZE, size(?TOMBSTONE0)).
% Size of tombstone + 32 bit file id
-define(TOMBSTONE1_SIZE, (size(?TOMBSTONE1_BIN) + 4)).
-define(TOMBSTONE2_SIZE, (size(?TOMBSTONE2_BIN) + 4)).
% Change this to the largest size a tombstone value can have if more added.
-define(MAX_TOMBSTONE_SIZE, ?TOMBSTONE2_SIZE).
% Notice that tombstone version 1 and 2 are the same size, so not tested below
-define(IS_TOMBSTONE_SIZE(S), (S == ?TOMBSTONE0_SIZE orelse S == ?TOMBSTONE1_SIZE)).

-define(OFFSETFIELD_V1, 64).
-define(TOMBSTONEFIELD_V2, 1).
-define(OFFSETFIELD_V2, 63).
-define(TSTAMPFIELD, 32).
-define(KEYSIZEFIELD, 16).
-define(TOTALSIZEFIELD, 32).
-define(VALSIZEFIELD, 32).
-define(CRCSIZEFIELD, 32).
-define(HEADER_SIZE, 14). % 4 + 4 + 2 + 4 bytes
-define(MAXKEYSIZE, 2#1111111111111111).
-define(MAXVALSIZE, 2#11111111111111111111111111111111).
-define(MAXOFFSET_V2, 16#7fffffffffffffff). % max 63-bit unsigned

%% for hintfile validation
-define(CHUNK_SIZE, 65535).
-define(MIN_CHUNK_SIZE, 1024).
-define(MAX_CHUNK_SIZE, 134217728).

-define(TEST_FILEPATH, "_build/test/log").
