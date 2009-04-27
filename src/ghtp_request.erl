-module(ghtp_request).

-export([execute/4]).

-import(ghtp_utils, [
		header_exists/2,
		header_value/2,
		header_value/3,
		status_line/2,
		format_headers/1
	]).

-include("gen_httpd_int.hrl").

-define(TYPE(REPLY), element(1, REPLY)).
-define(STATUS(REPLY), element(2, REPLY)).
-define(HDRS(REPLY), element(3, REPLY)).
-define(BODY(REPLY), element(4, REPLY)).
-define(CBSTATE(REPLY), element(size(REPLY), REPLY)).

execute(CB, CBState, Socket, Request) ->
	Method = Request#request.method,
	Vsn = Request#request.vsn,
	URI = Request#request.uri,
	ReqHdrs = Request#request.headers,
	Entity = entity(Request, Socket),
	case CB:handle_request(Method, URI, Vsn, ReqHdrs, Entity, CBState) of
		{reply, Status, ReplyHdrs, Body, NextCBState} ->
			KeepAlive =
				handle_reply(Socket, Vsn, ReqHdrs, Status, ReplyHdrs, Body),
			exit({done, KeepAlive, NextCBState});
		Other ->
			erlang:error({bad_return, Other})
	end.

handle_reply(Socket, Vsn, ReqHdrs, Status, ReplyHdrs, Body) ->
	HdrKeepAlive = keep_alive(Vsn, ReqHdrs, ReplyHdrs),
	case handle_body(ReplyHdrs, Body) of
		{chunked, Hdrs, Chunk, ReaderFun} ->
			send_status_and_hdr(Socket, Vsn, Status, Hdrs),
			send_chunk(Socket, Chunk),
			case send_chunks(Socket, ReaderFun) of
				false -> false;
				true  -> HdrKeepAlive
			end;
		{chunked, Hdrs, ReaderFun} ->
			send_status_and_hdr(Socket, Vsn, Status, Hdrs),
			case send_chunks(Socket, ReaderFun) of
				false -> false;
				true  -> HdrKeepAlive
			end;
		{partial, Hdrs, Part, ReaderFun} ->
			send_status_and_hdr(Socket, Vsn, Status, Hdrs),
			gen_tcpd:send(Socket, Part),
			send_parts(Socket, ReaderFun),
			HdrKeepAlive;
		{complete, Hdrs, Body} ->
			Data = format_response(Vsn, Status, Hdrs, Body),
			gen_tcpd:send(Socket, Data),
			HdrKeepAlive
	end.

send_parts(Socket, Reader) ->
	case Reader() of
		{data, D} ->
			gen_tcpd:send(Socket, D),
			send_parts(Socket, Reader);
		end_of_data ->
			ok;
		Other ->
			erlang:error({bad_return, Other})
	end.

send_chunks(Socket, Reader) ->
	case Reader() of
		{chunk, C} ->
			send_chunk(Socket, C),
			send_chunks(Socket, Reader);
		{trailers, T} ->
			% We've already done some protocol checks for this since we
			% checked when the status and headers was sent. We're just
			% checking again so that we're not getting any Connection: close
			% trailers.
			KeepAlive = case ghtp_utils:header_value("connection", T) of
				"close" -> false;
				_       -> true
			end,
			gen_tcpd:send(Socket, ghtp_utils:format_headers(T)),
			KeepAlive;
		Other ->
			erlang:error({bad_return, Other})
	end.

send_chunk(Socket, Chunk) ->
	ChunkSize = iolist_size(Chunk),
	Data = [erlang:integer_to_list(ChunkSize, 16), "\r\n", Chunk],
	gen_tcpd:send(Socket, Data).

send_status_and_hdr(Socket, Vsn, Status, Hdrs) ->
	gen_tcpd:send(Socket, format_response(Vsn, Status, Hdrs)).

format_response(Vsn, Status, Hdrs) ->
	StatusLine = status_line(Vsn, Status),
	FormatedHdrs = format_headers(Hdrs),
	[StatusLine, FormatedHdrs].

format_response(Vsn, Status, Hdrs, Body) ->
	[format_response(Vsn, Status, Hdrs), Body].

entity(#request{method = "POST", headers = Hdrs}, Socket) ->
	{entity_type(Hdrs), Socket};
entity(#request{method = "PUT", headers = Hdrs}, Socket) ->
	{entity_type(Hdrs), Socket};
entity(_, _) ->
	undefined.

entity_type(Hdrs) ->
	TransferEncoding = string:to_lower(
		header_value("transfer-encoding", Hdrs, "identity")
	),
	case TransferEncoding of
		"identity" -> identity;
		"chunked" -> chunked
	end.

handle_body(Hdrs, {partial, Reader}) ->
	Type = case header_exists("content-length", Hdrs) of
		true  -> partial;
		false -> chunked
	end,
	UpdatedHdrs = case header_exists("transfer-encoding", Hdrs) of
		true  -> Hdrs;
		false -> [{"Transfer-Encoding", "chunked"} | Hdrs]
	end,
	{Type, UpdatedHdrs, Reader};
handle_body(Hdrs, {partial, Part, Reader}) ->
	{Type, UpdatedHdrs, _} = handle_body(Hdrs, {partial, Reader}),
	{Type, UpdatedHdrs, Part, Reader};
handle_body(Hdrs, Body) when is_list(Body); is_binary(Body) ->
	UpdatedHdrs = case header_exists("content-length", Hdrs) of
		false ->
			Length = iolist_size(Body),
			[{"Content-Length", integer_to_list(Length)} | Hdrs];
		true  ->
			Hdrs
	end,
	{complete, UpdatedHdrs, Body};
handle_body(_, Body) ->
	erlang:error({bad_return, {body, Body}}).

keep_alive(Vsn, ReqHdrs, RespHdrs) ->
	% First of all, let the callback module decide
	case header_value("connection", RespHdrs) of
		"close" -> 
			false;
		_ -> % no preference (that we understand)
			case Vsn of
				{0,_} -> pre_1_1_keep_alive(ReqHdrs);
				{1,0} -> pre_1_1_keep_alive(ReqHdrs);
				{1,_} -> post_1_0_keep_alive(ReqHdrs)
			end
	end.

pre_1_1_keep_alive(Hdrs) ->
	case string:to_lower(header_value("connection", Hdrs, "")) of
		"keep-alive" -> true;
		_            -> false
	end.

post_1_0_keep_alive(Hdrs) ->
	case ghtp_utils:header_value("connection", Hdrs) of
		"close" -> false;
		_       -> true
	end.
