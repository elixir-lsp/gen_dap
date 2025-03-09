defmodule GenDAP.Test do
  @moduledoc """
  Conveniences for testing GenDAP processes.
  """
  import ExUnit.Callbacks
  import ExUnit.Assertions
  @json_module Application.compile_env!(:gen_dap, :json_module)

  @connect_opts [:binary, packet: :raw, active: false]

  @typedoc """
  The test server data structure.
  """
  @opaque server :: %{
            dap: pid(),
            dap_id: atom(),
            buffer: pid(),
            buffer_id: atom(),
            port: integer()
          }

  @typedoc """
  The test client data structure.
  """
  @opaque client :: %{socket: :gen_tcp.socket(), listener: pid()}

  @doc """
  Starts a new server.

  ## Usage

  ```elixir
  import GenDAP.Test

  server = server(MyDAP, some_arg: some_arg)
  ```
  """
  @spec server(mod :: atom()) :: server()
  def server(mod, opts \\ []) do
    buffer_id = Keyword.get(opts, :buffer_id, :buffer)
    dap_id = Keyword.get(opts, :dap_id, :dap)

    buffer =
      start_supervised!({GenDAP.Buffer, communication: {GenDAP.Communication.TCP, [port: 0]}},
        id: buffer_id
      )

    {:ok, port} = :inet.port(GenDAP.Buffer.comm_state(buffer).lsocket)

    dap =
      start_supervised!({mod, Keyword.merge([buffer: buffer], opts)}, id: dap_id)

    %{dap: dap, buffer: buffer, port: port, buffer_id: buffer_id, dap_id: dap_id}
  end

  @doc """
  Starts a new DAP client for the given server.

  The "client" is equivalent to a text editor.

  ## Usage

  ```elixir
  import GenDAP.Test

  server = server(MyDAP, some_arg: some_arg)
  client = client(server)
  ```
  """
  @spec client(server()) :: client()
  def client(server) do
    start_time = System.monotonic_time(:millisecond)

    {:ok, socket} = connect(server.port, start_time)

    me = self()

    {:ok, listener} =
      Task.start_link(fn ->
        Stream.resource(
          fn -> "" end,
          fn buffer ->
            case GenDAP.Communication.TCP.read(%{socket: socket}, buffer) do
              :eof ->
                {:halt, :ok}

              {:ok, body, buffer} ->
                send(me, @json_module.decode!(body))

                {[body], buffer}
            end
          end,
          fn
            :ok ->
              :ok

            {:error, reason} ->
              IO.warn("Unable to read from device: #{inspect(reason)}")

            other ->
              IO.warn(
                "Ended stream with value: #{inspect(other)}. This was probably due to something going wrong."
              )
          end
        )
        |> Enum.to_list()
      end)

    %{socket: socket, listener: listener}
  end

  @doc """
  Shuts down an DAP server.
  """
  @spec shutdown_server!(server :: server()) :: :ok
  def shutdown_server!(server) do
    stop_supervised!(server.buffer_id)
    stop_supervised!(server.dap_id)

    :ok
  end

  @doc """
  Shuts down an DAP client.
  """
  @spec shutdown_client!(client :: client()) :: :ok
  def shutdown_client!(client) do
    Process.exit(client.listener, :normal)

    :ok
  end

  @doc ~S"""
  Send a request from the client to the server.

  The response from the server will be sent as a message to the current process and can be asserted on using `GenDAP.Test.assert_result/3`.

  ## Usage

  ```elixir
  import GenDAP.Test

  request(client, %{
    method: "initialize",
    id: 1,
    jsonrpc: "2.0",
    params: %{capabilities: %{}, rootUri: "file://#{root_path}"}
  })
  ```
  """
  @spec request(client(), term()) ::
          {:ok, any()} | {:error, :closed | {:timeout, binary()} | :inet.posix()}
  def request(%{socket: socket}, body) do
    GenDAP.Communication.TCP.write(@json_module.encode_to_iodata!(body), %{socket: socket})
  end

  @doc """
  Send a notification from the client to the server.

  ## Usage

  ```elixir
  import GenDAP.Test

  notify(client, %{
    method: "initialized",
    jsonrpc: "2.0",
    params: %{}
  })
  ```
  """
  @spec notify(client(), term()) :: :ok
  def notify(%{socket: socket}, body) do
    GenDAP.Communication.TCP.write(@json_module.encode_to_iodata!(body), %{socket: socket})
  end

  @doc """
  Simple helper to determine whether the DAP process is alive.
  """
  @spec alive?(server()) :: boolean()
  def alive?(%{dap: dap}) do
    Process.alive?(dap)
  end

  @doc ~S"""
  Assert on the successful response of a request that was sent with `GenDAP.Test.request/2`.

  The second argument is a pattern, similar to `ExUnit.Assertions.assert_receive/3`.

  ## Usage

  ```elixir
  import GenDAP.Test

  id = 1

  request(client, %{
    method: "initialize",
    id: id,
    jsonrpc: "2.0",
    params: %{capabilities: %{}, rootUri: "file://#{root_path}"}
  })

  assert_result(^id, %{
    "capabilities" => %{
      "textDocumentSync" => %{
        "openClose" => true,
        "save" => %{
          "includeText" => true
        },
        "change" => 1
      }
    },
    "serverInfo" => %{"name" => "Credo"}
  })
  ```
  """
  defmacro assert_result_with_body(
             seq,
             request_seq,
             command,
             pattern,
             timeout \\ Application.get_env(:ex_unit, :assert_receive_timeout)
           ) do
    quote do
      assert_receive %{
                       "body" => unquote(pattern),
                       "command" => unquote(command),
                       "request_seq" => unquote(request_seq),
                       "seq" => unquote(seq) = seq,
                       "success" => true,
                       "type" => "response"
                     },
                     unquote(timeout)

      assert seq > 0
    end
  end

  defmacro assert_result(
             seq,
             request_seq,
             command,
             timeout \\ Application.get_env(:ex_unit, :assert_receive_timeout)
           ) do
    quote do
      assert_receive %{
                       "command" => unquote(command),
                       "request_seq" => unquote(request_seq),
                       "seq" => unquote(seq) = seq,
                       "success" => true,
                       "type" => "response"
                     },
                     unquote(timeout)

      assert seq > 0
    end
  end

  @doc ~S"""
  Assert on the error response of a request that was sent with `GenDAP.Test.request/2`.

  The second argument is a pattern, similar to `ExUnit.Assertions.assert_receive/3`.

  ## Usage

  ```elixir
  import GenDAP.Test

  id = 3

  request(client, %{
    method: "textDocument/documentSymbol",
    id: id,
    jsonrpc: "2.0",
    params: %{
      textDocument: %{
        uri: "file://file/doesnt/matter.ex"
      }
    }
  })

  assert_error(^id, %{
    "code" => -32601,
    "message" => "Method Not Found"
  })
  ```
  """
  defmacro assert_error(
             seq,
             request_seq,
             command,
             message,
             pattern,
             timeout \\ Application.get_env(:ex_unit, :assert_receive_timeout)
           ) do
    quote do
      assert_receive %{
                       "type" => "response",
                       "request_seq" => unquote(request_seq),
                       "seq" => unquote(seq) = seq,
                       "success" => false,
                       "command" => unquote(command),
                       "message" => unquote(message),
                       "body" => unquote(pattern)
                     },
                     unquote(timeout)

      assert seq > 0
    end
  end

  @doc ~S"""
  Assert on a notification that was sent from the server.

  The second argument is a pattern, similar to `ExUnit.Assertions.assert_receive/3`.

  ## Usage

  ```elixir
  import GenDAP.Test

  notify(client, %{method: "initialized", jsonrpc: "2.0", params: %{}})

  assert_notification("window/logMessage", %{
    "message" => "[MyDAP] DAP Initialized!",
    "type" => 4
  })
  ```
  """
  defmacro assert_notification_with_body(
             seq,
             method,
             pattern,
             timeout \\ Application.get_env(:ex_unit, :assert_receive_timeout)
           ) do
    quote do
      assert_receive %{
                       "type" => "event",
                       "event" => unquote(method),
                       "seq" => unquote(seq) = seq,
                       "body" => unquote(pattern)
                     },
                     unquote(timeout)

      assert seq > 0
    end
  end

  defmacro assert_notification(
             seq,
             method,
             timeout \\ Application.get_env(:ex_unit, :assert_receive_timeout)
           ) do
    quote do
      assert_receive %{
                       "type" => "event",
                       "event" => unquote(method),
                       "seq" => unquote(seq) = seq
                     },
                     unquote(timeout)

      assert seq > 0
    end
  end

  @doc ~S"""
  Assert on a request that was sent from the server.

  ## Usage

  ```elixir
  assert_request(client, "client/registerCapability", 1000, fn params ->
    assert params == %{
             "registrations" => [
               %{
                 "id" => "file-watching",
                 "method" => "workspace/didChangeWatchedFiles",
                 "registerOptions" => %{
                   "watchers" => [
                     %{
                       "globPattern" => "{lib|test}/**/*.{ex|exs|heex|eex|leex|surface}"
                     }
                   ]
                 }
               }
             ]
           }

    nil
  end)
  ```
  """
  defmacro assert_request(
             client,
             reverse_request_seq,
             command,
             timeout \\ Application.get_env(:ex_unit, :assert_receive_timeout),
             callback
           ) do
    json_module = @json_module

    quote do
      assert_receive %{
                       "type" => "request",
                       "seq" => unquote(reverse_request_seq),
                       "command" => unquote(command),
                       "arguments" => params
                     },
                     unquote(timeout)

      response =
        case unquote(callback).(params) do
          {:ok, result} ->
            %{
              type: "response",
              request_seq: unquote(reverse_request_seq),
              seq: System.unique_integer([:positive]),
              command: unquote(command),
              success: true,
              body: result
            }

          {:error, message, body} ->
            %{
              type: "response",
              request_seq: unquote(reverse_request_seq),
              seq: System.unique_integer([:positive]),
              command: unquote(command),
              success: false,
              message: message,
              body: body
            }
        end

      GenDAP.Communication.TCP.write(
        unquote(json_module).encode_to_iodata!(response),
        unquote(client)
      )
    end
  end

  defp connect(port, start_time) do
    now = System.monotonic_time(:millisecond)

    case :gen_tcp.connect(~c"localhost", port, @connect_opts) do
      {:error, :econnrefused} when now - start_time > 5000 ->
        connect(port, start_time)

      other ->
        other
    end
  end
end
