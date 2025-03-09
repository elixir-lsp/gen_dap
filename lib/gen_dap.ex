defmodule GenDAP do
  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  defmodule InvalidRequest do
    defexception message: nil

    @impl true
    def exception({request, errors}) do
      msg = """
      Invalid request from the client

      Received: #{inspect(request)}
      Errors: #{inspect(errors)}
      """

      %__MODULE__{message: msg}
    end
  end

  defmodule InvalidResponse do
    defexception message: nil

    @impl true
    def exception({method, response, errors}) do
      msg = """
      Invalid response for request #{method}.

      Response: #{inspect(response)}
      Errors: #{inspect(errors)}
      """

      %__MODULE__{message: msg}
    end

    def exception({method, response}) do
      msg = """
      Invalid response for request #{method}.

      Response: #{inspect(response)}
      """

      %__MODULE__{message: msg}
    end
  end

  defmodule InvalidMessage do
    defexception message: nil

    @impl true
    def exception(message) do
      msg = """
      Invalid message from the client

      Given: #{inspect(message)}
      """

      %__MODULE__{message: msg}
    end
  end

  alias GenDAP.DAP

  defmacro __using__(_) do
    quote do
      @behaviour GenDAP

      require Logger

      import GenDAP.DAP

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :worker,
          restart: :permanent,
          shutdown: 500
        }
      end

      @impl true
      def handle_info(_, state) do
        Logger.warning("Unhandled message passed to handle_info/2")

        {:noreply, state}
      end

      defoverridable handle_info: 2
    end
  end

  require Logger

  @doc """
  The callback responsible for initializing the process.

  Receives the `t:GenDAP.DAP.t/0` token as the first argument and the arguments that were passed to `GenDAP.start_link/3` as the second.

  ## Usage

  ```elixir
  @impl true
  def init(dap, args) do
    some_arg = Keyword.fetch!(args, :some_arg)

    {:ok, assign(dap, static_assign: :some_assign, some_arg: some_arg)}
  end
  ```
  """
  @callback init(dap :: GenDAP.DAP.t(), init_arg :: term()) :: {:ok, GenDAP.DAP.t()}
  @doc """
  The callback responsible for handling requests from the client.

  Receives the request struct as the first argument and the DAP token `t:GenDAP.DAP.t/0` as the second.

  ## Usage

  ```elixir
  @impl true
  def handle_request(%Initialize{params: %InitializeParams{root_uri: root_uri}}, dap) do
    {:reply,
     %InitializeResult{
       capabilities: %ServerCapabilities{
         text_document_sync: %TextDocumentSyncOptions{
           open_close: true,
           save: %SaveOptions{include_text: true},
           change: TextDocumentSyncKind.full()
         }
       },
       server_info: %{name: "MyDAP"}
     }, assign(dap, root_uri: root_uri)}
  end
  ```
  """
  @callback handle_request(request :: term(), state) ::
              {:reply, reply :: term(), state}
              | {:noreply, state}
              | {:async_reply, callback :: (-> term()), state}
            when state: GenDAP.DAP.t()

  @doc """
  The callback responsible for handling normal messages.

  Receives the message as the first argument and the DAP token `t:GenDAP.DAP.t/0` as the second.

  ## Usage

  ```elixir
  @impl true
  def handle_info(message, dap) do
    # handle the message

    {:noreply, dap}
  end
  ```
  """
  @callback handle_info(message :: any(), state) :: {:noreply, state} when state: GenDAP.DAP.t()

  @options_schema NimbleOptions.new!(
                    buffer: [
                      type: {:or, [:pid, :atom]},
                      doc: "The `t:pid/0` or name of the `GenDAP.Buffer` process."
                    ],
                    name: [
                      type: :atom,
                      doc:
                        "Used for name registration as described in the \"Name registration\" section in the documentation for `GenServer`."
                    ]
                  )

  @doc """
  Starts a `GenDAP` process that is linked to the current process.

  ## Options

  #{NimbleOptions.docs(@options_schema)}
  """
  def start_link(module, init_args, opts) do
    opts = NimbleOptions.validate!(opts, @options_schema)

    :proc_lib.start_link(__MODULE__, :init, [
      {module, init_args, Keyword.take(opts, [:name, :buffer]), self()}
    ])
  end

  @doc false
  def init({module, init_args, opts, parent}) do
    me = self()
    buffer = opts[:buffer]
    dap = %DAP{mod: module, pid: me, buffer: buffer}

    case module.init(dap, init_args) do
      {:ok, %DAP{} = dap} ->
        deb = :sys.debug_options([])
        if opts[:name], do: Process.register(self(), opts[:name])
        :proc_lib.init_ack(parent, {:ok, me})

        GenDAP.Buffer.listen(buffer, me)

        loop(dap, parent, deb)
    end
  end

  @doc """
  Sends a request from the client to the DAP process.

  Generally used by the `GenDAP.Communication.Adapter` implementation to forward messages from the buffer to the DAP process.

  You shouldn't need to use this to implement a language server.
  """
  @spec request_server(pid(), message) :: message when message: term()
  def request_server(pid, request) do
    from = self()
    message = {:request, from, request}
    send(pid, message)
  end

  @doc ~S'''
  Sends a notification to the client from the DAP process.

  ## Usage

  ```elixir
  GenDAP.notify(dap, %TextDocumentPublishDiagnostics{
    params: %PublishDiagnosticsParams{
      uri: "file://#{file}",
      diagnostics: diagnostics
    }
  })
  ```
  '''
  @spec notify(GenDAP.DAP.t(), notification :: any()) :: :ok
  def notify(%{buffer: buffer}, notification) do
    Logger.debug("sent event server -> client #{notification.event}",
      event: notification.event
    )

    :telemetry.span([:gen_dap, :notify, :server], %{}, fn ->
      result =
        GenDAP.Buffer.outgoing(buffer, dump!(notification.__struct__.schematic(), notification))

      {result, %{event: notification.event}}
    end)
  end

  @doc ~S'''
  Sends a request to the client from the DAP process.

  ## Usage

  ```elixir
  GenDAP.request(dap, %ClientRegisterCapability{
    id: System.unique_integer([:positive]),
    params: params
  })
  ```
  '''
  @spec request(GenDAP.DAP.t(), request :: any(), timeout :: :infinity | non_neg_integer()) ::
          any()
  def request(%{buffer: buffer}, request, timeout \\ :infinity) do
    Logger.debug("sent request server -> client #{request.command}",
      command: request.command
    )

    :telemetry.span([:gen_dap, :request, :server], %{}, fn ->
      result =
        GenDAP.Buffer.outgoing_sync(
          buffer,
          dump!(request.__struct__.schematic(), request),
          timeout
        )

      {:ok, mapped_result} = GenDAP.Responses.new(result)

      {mapped_result, %{command: request.command}}
    end)
  end

  defp write_debug(device, event, name) do
    IO.write(device, "#{inspect(name)} event = #{inspect(event)}\n")
  end

  defp loop(%DAP{} = dap, parent, deb) do
    receive do
      {:system, from, request} ->
        :sys.handle_system_msg(request, from, parent, __MODULE__, deb, dap)

      {:request, from, request} ->
        deb = :sys.handle_debug(deb, &write_debug/3, __MODULE__, {:in, :request, from})

        start = System.system_time(:microsecond)
        :telemetry.execute([:gen_dap, :request, :client, :start], %{})

        attempt(
          dap,
          "Last message received: handle_request #{inspect(request)}",
          [:gen_dap, :request, :client],
          fn
            {:error, error} ->
              {:ok, packet} =
                Schematic.dump(
                  GenDAP.Structures.ErrorResponse.schematic(),
                  %GenDAP.Structures.ErrorResponse{
                    request_seq: request["seq"],
                    message: error,
                    type: "response",
                    success: false,
                    command: request["command"],
                    seq: 0,
                    body: %{}
                  }
                )

              deb =
                :sys.handle_debug(deb, &write_debug/3, __MODULE__, {:out, :request, from})

              GenDAP.Buffer.outgoing(dap.buffer, packet)
              loop(dap, parent, deb)

            _ ->
              case GenDAP.Requests.new(request) do
                {:ok, %{seq: seq} = req} ->
                  Process.put(:request_seq, seq)

                  result =
                    :telemetry.span([:gen_dap, :handle_request], %{command: req.command}, fn ->
                      {dap.mod.handle_request(req, dap), %{}}
                    end)

                  case result do
                    {:reply, reply, %DAP{} = dap} ->
                      request_command = req.command
                      request_seq = req.seq
                      # if result is valid, continue, if not, we return an internal error
                      response =
                        case Schematic.dump(reply.__struct__.schematic(), reply) do
                          {:ok,
                           output = %{
                             "command" => ^request_command,
                             "request_seq" => ^request_seq
                           }} ->
                            output

                          {:ok, _invalid_response} ->
                            # response is for the wrong command
                            exception = InvalidResponse.exception({req.command, reply})
                            Logger.error(Exception.format(:error, exception))

                            {:ok, output} =
                              Schematic.dump(
                                GenDAP.Structures.ErrorResponse.schematic(),
                                %GenDAP.Structures.ErrorResponse{
                                  request_seq: request["seq"],
                                  message: exception.message,
                                  type: "response",
                                  success: false,
                                  command: request["command"],
                                  seq: 0,
                                  body: %{}
                                }
                              )

                            output

                          {:error, errors} ->
                            # response is invalid
                            exception = InvalidResponse.exception({req.command, reply, errors})

                            Logger.error(Exception.format(:error, exception))

                            {:ok, output} =
                              Schematic.dump(
                                GenDAP.Structures.ErrorResponse.schematic(),
                                %GenDAP.Structures.ErrorResponse{
                                  request_seq: Process.get(:request_seq),
                                  message: exception.message,
                                  type: "response",
                                  success: false,
                                  command: req.command,
                                  seq: req.seq,
                                  body: %{}
                                }
                              )

                            output
                        end

                      deb =
                        :sys.handle_debug(deb, &write_debug/3, __MODULE__, {:out, :request, from})

                      GenDAP.Buffer.outgoing(dap.buffer, response)

                      duration = System.system_time(:microsecond) - start

                      Logger.debug(
                        "handled request client -> server #{req.command} in #{format_time(duration)}",
                        seq: req.seq,
                        command: req.command
                      )

                      :telemetry.execute([:gen_dap, :request, :client, :stop], %{
                        duration: duration
                      })

                      loop(dap, parent, deb)

                    {:noreply, dap} ->
                      duration = System.system_time(:microsecond) - start

                      Logger.debug(
                        "handled request client -> server #{req.command} in #{format_time(duration)}",
                        seq: req.seq,
                        command: req.command
                      )

                      :telemetry.execute([:gen_dap, :request, :client, :stop], %{
                        duration: duration
                      })

                      loop(dap, parent, deb)

                    {:async_reply, callback, %DAP{} = dap} ->
                      request_command = req.command
                      request_seq = req.seq

                      Logger.debug(
                        "starting async task for request client -> server #{req.command}",
                        seq: req.seq,
                        command: req.command
                      )

                      Task.start(fn ->
                        try do
                          reply = callback.()

                          response =
                            case Schematic.dump(reply.__struct__.schematic(), reply) do
                              {:ok,
                               output = %{
                                 "command" => ^request_command,
                                 "request_seq" => ^request_seq
                               }} ->
                                output

                              {:ok, _invalid_response} ->
                                # response is for the wrong command
                                exception = InvalidResponse.exception({req.command, reply})
                                Logger.error(Exception.format(:error, exception))

                                {:ok, output} =
                                  Schematic.dump(
                                    GenDAP.Structures.ErrorResponse.schematic(),
                                    %GenDAP.Structures.ErrorResponse{
                                      request_seq: request["seq"],
                                      message: exception.message,
                                      type: "response",
                                      success: false,
                                      command: request["command"],
                                      seq: 0,
                                      body: %{}
                                    }
                                  )

                                output

                              {:error, errors} ->
                                # response is invalid
                                exception =
                                  InvalidResponse.exception({req.command, reply, errors})

                                Logger.error(Exception.format(:error, exception))

                                {:ok, output} =
                                  Schematic.dump(
                                    GenDAP.Structures.ErrorResponse.schematic(),
                                    %GenDAP.Structures.ErrorResponse{
                                      request_seq: request_seq,
                                      message: exception.message,
                                      type: "response",
                                      success: false,
                                      command: req.command,
                                      seq: req.seq,
                                      body: %{}
                                    }
                                  )

                                output
                            end

                          GenDAP.Buffer.outgoing(dap.buffer, response)

                          Logger.debug(
                            "completed async task for request client -> server #{req.command}",
                            seq: req.seq,
                            command: req.command
                          )
                        rescue
                          e ->
                            message = Exception.format(:error, e, __STACKTRACE__)
                            Logger.error("Async task failed: " <> message)

                            {:ok, output} =
                              Schematic.dump(
                                GenDAP.Structures.ErrorResponse.schematic(),
                                %GenDAP.Structures.ErrorResponse{
                                  request_seq: request_seq,
                                  message: "Async task failed: " <> message,
                                  type: "response",
                                  success: false,
                                  command: request_command,
                                  seq: 0,
                                  body: %{}
                                }
                              )

                            GenDAP.Buffer.outgoing(dap.buffer, output)
                        end
                      end)

                      # Don't wait for task completion, continue processing other messages
                      loop(dap, parent, deb)
                  end

                {:error, errors} ->
                  # the payload is not parseable at all, other than being valid JSON and having
                  # a `seq` and `command` property
                  exception = InvalidRequest.exception({request, errors})

                  Logger.error(Exception.format(:error, exception))

                  {:ok, output} =
                    Schematic.dump(
                      GenDAP.Structures.ErrorResponse.schematic(),
                      %GenDAP.Structures.ErrorResponse{
                        request_seq: request["seq"],
                        message: exception.message,
                        type: "response",
                        success: false,
                        command: request["command"],
                        seq: 0,
                        body: %{}
                      }
                    )

                  deb =
                    :sys.handle_debug(deb, &write_debug/3, __MODULE__, {:out, :request, from})

                  GenDAP.Buffer.outgoing(dap.buffer, output)

                  loop(dap, parent, deb)
              end
          end
        )

      message ->
        deb = :sys.handle_debug(deb, &write_debug/3, __MODULE__, {:in, :info, message})
        start = System.system_time(:microsecond)
        :telemetry.execute([:gen_dap, :info, :start], %{})

        attempt(
          dap,
          "Last message received: handle_info #{inspect(message)}",
          [:gen_dap, :info],
          fn
            {:error, _} ->
              loop(dap, parent, deb)

            _ ->
              result =
                :telemetry.span([:gen_dap, :handle_info], %{}, fn ->
                  {dap.mod.handle_info(message, dap), %{}}
                end)

              case result do
                {:noreply, %DAP{} = dap} ->
                  duration = System.system_time(:microsecond) - start
                  :telemetry.execute([:gen_dap, :info, :stop], %{duration: duration})
                  loop(dap, parent, deb)
              end
          end
        )
    end
  end

  defp format_time(time) when time < 1000 do
    "#{time}µs"
  end

  defp format_time(time) do
    "#{System.convert_time_unit(time, :microsecond, :millisecond)}ms"
  end

  @spec attempt(DAP.t(), String.t(), list(atom()), (:try | {:error, String.t()} -> any())) ::
          no_return()
  defp attempt(dap, message, prefix, callback) do
    callback.(:try)
  rescue
    e ->
      :telemetry.execute(prefix ++ [:exception], %{message: message})

      message = Exception.format(:error, e, __STACKTRACE__)
      Logger.error(message)
      error(dap, message)

      callback.({:error, message})
  end

  defp dump!(schematic, structure) do
    {:ok, output} = Schematic.dump(schematic, structure)
    output
  end

  @doc false
  def system_continue(parent, deb, state) do
    loop(state, parent, deb)
  end

  @doc false
  def system_terminate(reason, _parent, _deb, _chs) do
    exit(reason)
  end

  @doc false
  def system_get_state(state) do
    {:ok, state}
  end

  @doc false
  def system_replace_state(state_fun, state) do
    new_state = state_fun.(state)

    {:ok, new_state, new_state}
  end

  @doc """
  Send a `window/logMessage` error notification to the client.

  See `GenDAP.Enumerations.MessageType.error/0`.

  ## Usage

  ```elixir
  GenDAP.error(dap, "Failed to compiled!")
  ```
  """
  @spec error(GenDAP.DAP.t(), String.t()) :: :ok
  def error(dap, message) do
    log_message(dap, "error", message)
  end

  @doc """
  Send a `window/logMessage` error notification to the client.

  See `GenDAP.Enumerations.MessageType.warning/0`.

  ## Usage

  ```elixir
  GenDAP.warning(dap, "Variable `foo` is unused.")
  ```
  """
  @spec warning(GenDAP.DAP.t(), String.t()) :: :ok
  def warning(dap, message) do
    log_message(dap, "warning", message)
  end

  @doc """
  Send a `window/logMessage` info notification to the client.

  See `GenDAP.Enumerations.MessageType.info/0`.

  ## Usage

  ```elixir
  GenDAP.info(dap, "Compilation complete!")
  ```
  """
  @spec info(GenDAP.DAP.t(), String.t()) :: :ok
  def info(dap, message) do
    log_message(dap, "info", message)
  end

  @doc """
  Send a `window/logMessage` log notification to the client.

  See `GenDAP.Enumerations.MessageType.log/0`.

  ## Usage

  ```elixir
  GenDAP.log(dap, "Starting compilation.")
  ```
  """
  @spec log(GenDAP.DAP.t(), String.t()) :: :ok
  def log(dap, message) do
    log_message(dap, "debug", message)
  end

  defp log_message(dap, level, message) do
    GenDAP.notify(dap, %GenDAP.Events.OutputEvent{
      seq: 0,
      body: %{category: "console", output: "[#{level}] " <> maybe_append_newline(message)}
    })
  end

  defp maybe_append_newline(message) do
    unless String.ends_with?(message, "\n") do
      message <> "\n"
    else
      message
    end
  end
end
