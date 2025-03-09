defmodule GenDAPTest do
  use ExUnit.Case, async: true

  import GenDAP.Test
  import ExUnit.CaptureLog

  setup do
    server = server(GenDAPTest.ExampleServer, test_pid: self())
    client = client(server)

    [server: server, client: client]
  end

  test "stores the user state and internal state", %{server: server} do
    assert alive?(server)

    assert %GenDAP.DAP{
             assigns: %{foo: :bar, test_pid: self()},
             buffer: server.buffer,
             pid: server.dap,
             mod: GenDAPTest.ExampleServer
           } ==
             :sys.get_state(server.dap)
  end

  test "can receive and reply to a synchronous request", %{client: client} do
    request_seq = System.unique_integer([:positive])

    assert :ok ==
             request(client, %{
               "type" => "request",
               "command" => "initialize",
               "seq" => request_seq,
               "arguments" => %{
                 "adapterID" => "VSCode"
               }
             })

    assert_result_with_body(
      _response_seq,
      ^request_seq,
      "initialize",
      %{"supportsCancelRequest" => true},
      500
    )
  end

  test "can receive and reply to an asynchronous request", %{client: client} do
    request_seq = System.unique_integer([:positive])

    assert :ok ==
             request(client, %{
               "type" => "request",
               "command" => "evaluate",
               "seq" => request_seq,
               "arguments" => %{
                 "expression" => "100"
               }
             })

    assert_result_with_body(
      _response_seq,
      ^request_seq,
      "evaluate",
      %{"result" => "1"},
      500
    )
  end

  test "can send a reverse request from the server to the client", %{client: client} do
    request_seq = System.unique_integer([:positive])

    assert :ok ==
             request(client, %{
               "type" => "request",
               "command" => "continue",
               "seq" => request_seq,
               "arguments" => %{
                 "threadId" => 123
               }
             })

    assert_request(client, reverse_request_seq, "runInTerminal", 1000, fn arguments ->
      assert arguments == %{
               "cwd" => ".",
               "args" => ["elixir", "--sname", "example_server", "--cookie", "example_cookie"]
             }

      {:ok, %{}}
    end)

    assert_result_with_body(
      response_seq,
      ^request_seq,
      "continue",
      %{"allThreadsContinued" => true},
      500
    )

    # the reverse request should be sent before the response
    assert reverse_request_seq < response_seq

    # TODO check if test pid received the result
  end

  test "server can send a notification", %{client: client} do
    request_seq = System.unique_integer([:positive])

    assert :ok ==
             request(client, %{
               "type" => "request",
               "command" => "pause",
               "seq" => request_seq,
               "arguments" => %{
                 "threadId" => 123
               }
             })

    assert_result(response_seq, ^request_seq, "pause", 500)

    assert_notification_with_body(
      event_seq,
      "thread",
      %{
        "reason" => "pause",
        "threadId" => 123
      },
      500
    )

    # the event should be sent before the response
    assert event_seq < response_seq
  end

  test "sends an error log on exception", %{server: server} do
    send(server.dap, :boom)

    assert_notification_with_body(
      _seq,
      "output",
      %{
        "category" => "console",
        "output" => output
      },
      300
    )

    assert output =~ "** (RuntimeError) boom"
  end

  test "returns an internal error when user code fails", %{client: client} do
    log =
      capture_log(fn ->
        request_seq = System.unique_integer([:positive])

        assert :ok ==
                 request(client, %{
                   type: "request",
                   command: "terminateThreads",
                   seq: request_seq,
                   arguments: %{
                     threadIds: [123]
                   }
                 })

        assert_notification_with_body(
          _seq,
          "output",
          %{
            "category" => "console",
            "output" => message
          },
          300
        )

        assert message =~ "(RuntimeError) boom"

        assert_error(
          _seq,
          ^request_seq,
          "terminateThreads",
          "** (RuntimeError) boom" <> _,
          %{},
          300
        )
      end)

    assert log =~ "[error] ** (RuntimeError) boom"
  end

  test "can receive a normal message with handle_info/2", %{server: server} do
    send(server.dap, "hi")

    assert_receive {:info, :ack}
  end

  test "can respond with an error", %{client: client} do
    request_seq = System.unique_integer([:positive])

    assert :ok ==
             request(client, %{
               type: "request",
               command: "source",
               seq: request_seq,
               arguments: %{
                 path: "foo",
                 sourceReference: 1
               }
             })

    assert_error(_seq, ^request_seq, "source", "Not implemented" <> _, %{}, 500)
  end

  test "can shutdown a client and server", %{client: client, server: server} do
    assert alive?(server)

    shutdown_client!(client)
    shutdown_server!(server)

    refute alive?(server)
  end

  test "returns an internal error and logs when the reply to a request is invalid", %{
    client: client
  } do
    request_seq = System.unique_integer([:positive])

    expected_msg =
      ~S'''
      ** (KeyError) key :__struct__ not found in: []
      '''

    log =
      capture_log(fn ->
        assert assert :ok ==
                        request(client, %{
                          type: "request",
                          command: "stackTrace",
                          seq: request_seq,
                          arguments: %{
                            threadId: 1
                          }
                        })

        assert_error(_seq, ^request_seq, "stackTrace", msg, %{}, 500)

        assert msg =~ expected_msg
      end)

    assert log =~ expected_msg
  end

  test "returns an internal error and logs when the reply to a request is of the wrong type", %{
    client: client
  } do
    request_seq = 123

    expected_msg =
      ~S'''
      Invalid response for request stackTrace.

      Response: %GenDAP.Requests.TerminateThreadsResponse{command: "terminateThreads", success: true, request_seq: 123, type: "response", seq: 0}
      '''

    log =
      capture_log(fn ->
        assert assert :ok ==
                        request(client, %{
                          type: "request",
                          command: "stackTrace",
                          seq: request_seq,
                          arguments: %{
                            threadId: 2
                          }
                        })

        assert_error(_seq, ^request_seq, "stackTrace", msg, %{}, 500)

        assert msg =~ expected_msg
      end)

    assert log =~ expected_msg
  end

  test "returns an internal error and logs when the reply to a request is missing required fields",
       %{
         client: client
       } do
    request_seq = 1543

    expected_msg =
      ~S'''
      Invalid response for request stackTrace.

      Response: %GenDAP.Requests.StackTraceResponse{body: %{}, command: "stackTrace", success: true, request_seq: 1543, type: "response", seq: 0}
      Errors: %{body: %{stack_frames: "expected a list"}}
      '''

    log =
      capture_log(fn ->
        assert assert :ok ==
                        request(client, %{
                          type: "request",
                          command: "stackTrace",
                          seq: request_seq,
                          arguments: %{
                            threadId: 3
                          }
                        })

        assert_error(_seq, ^request_seq, "stackTrace", msg, %{}, 500)

        assert msg =~ expected_msg
      end)

    assert log =~ expected_msg
  end

  test "returns an internal error and logs when the error reply to a request is missing required fields",
       %{
         client: client
       } do
    request_seq = 1543

    expected_msg =
      ~S'''
      Invalid response for request stackTrace.

      Response: %GenDAP.Structures.ErrorResponse{type: "response", success: false, seq: 0, request_seq: 1543, message: "boom", command: "stackTrace", body: %{error: %{}}}
      Errors: %{body: %{error: "expected a Elixir.GenDAP.Structures.Message struct"}}
      '''

    log =
      capture_log(fn ->
        assert assert :ok ==
                        request(client, %{
                          type: "request",
                          command: "stackTrace",
                          seq: request_seq,
                          arguments: %{
                            threadId: 4
                          }
                        })

        assert_error(_seq, ^request_seq, "stackTrace", msg, %{}, 500)

        assert msg =~ expected_msg
      end)

    assert log =~ expected_msg
  end

  test "returns an invalid request when the payload is not parseable, but is still deemed a request",
       %{client: client} do
    request_seq = System.unique_integer([:positive])

    assert :ok ==
             request(client, %{
               type: "request",
               command: "notSupported",
               seq: request_seq,
               arguments: %{
                 foo: "bar"
               }
             })

    assert_error(
      _seq,
      ^request_seq,
      "notSupported",
      "Invalid request from the client" <> _,
      %{},
      500
    )
  end

  test "logs when an invalid payload is received", %{client: client} do
    assert capture_log(fn ->
             assert :ok == notify(client, %{"random" => "stuff"})
             Process.sleep(100)
           end) =~ "Invalid message from the client"
  end
end
