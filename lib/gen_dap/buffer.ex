defmodule GenDAP.Buffer do
  @moduledoc """
  The data buffer between the DAP process and the communication channel.
  """
  use GenServer
  alias GenDAP.InvalidMessage

  require Logger
  @json_module Application.compile_env!(:gen_dap, :json_module)

  @options_schema NimbleOptions.new!(
                    communication: [
                      type: :mod_arg,
                      default: {GenDAP.Communication.Stdio, []},
                      doc:
                        "A `{module, args}` tuple, where `module` implements the `GenDAP.Communication.Adapter` behaviour."
                    ],
                    name: [
                      type: :atom,
                      doc:
                        "Used for name registration as described in the \"Name registration\" section in the documentation for `GenServer`."
                    ]
                  )

  @doc """
  Starts a `GenDAP.Buffer` process that is linked to the current process.

  ## Options

  #{NimbleOptions.docs(@options_schema)}
  """
  def start_link(opts) do
    opts = NimbleOptions.validate!(opts, @options_schema)
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc false
  def listen(server, dap) do
    GenServer.cast(server, {:listen, dap})
  end

  @doc false
  def incoming(server, packet) do
    GenServer.cast(server, {:incoming, packet})
  end

  @doc false
  def outgoing(server, packet) do
    GenServer.cast(server, {:outgoing, packet})
  end

  @doc false
  def outgoing_sync(server, packet, timeout \\ :infinity) do
    GenServer.call(server, {:outgoing_sync, packet}, timeout)
  end

  @doc false
  def comm_state(server) do
    GenServer.call(server, :comm_state)
  end

  @impl true
  def init(opts) do
    {comm, comm_args} = opts[:communication]
    {:ok, comm_data} = comm.init(comm_args)

    {:ok, %{comm: comm, comm_data: comm_data, awaiting_response: Map.new(), seq: 1}}
  end

  @impl true
  def handle_call(:comm_state, _from, %{comm_data: comm_data} = state) do
    {:reply, comm_data, state}
  end

  def handle_call({:outgoing_sync, packet}, from, state = %{seq: seq}) do
    :telemetry.span([:gen_dap, :buffer, :outgoing], %{kind: :sync}, fn ->
      :ok =
        state.comm.write(
          @json_module.encode_to_iodata!(packet |> Map.put("seq", seq)),
          state.comm_data
        )

      {:ok, %{}}
    end)

    {:noreply,
     %{
       state
       | awaiting_response: Map.put(state.awaiting_response, seq, {from, packet["command"]}),
         seq: seq + 1
     }}
  end

  @impl true
  def handle_cast({:incoming, packet}, %{dap: dap} = state) do
    state =
      :telemetry.span([:gen_dap, :buffer, :incoming], %{}, fn ->
        state =
          case @json_module.decode!(packet) do
            %{"request_seq" => request_seq, "type" => "response", "command" => command} = result
            when is_map_key(state.awaiting_response, request_seq) ->
              {{from, ^command}, awaiting_response} =
                Map.pop(state.awaiting_response, request_seq)

              GenServer.reply(from, result)

              %{state | awaiting_response: awaiting_response}

            %{"type" => "request", "seq" => _seq, "command" => _command} = request ->
              GenDAP.request_server(dap, request)
              state

            message ->
              # the payload is not parseable at all, other than being valid JSON
              exception = InvalidMessage.exception(message)

              Logger.warning(Exception.format(:error, exception))
              state
          end

        {state, %{}}
      end)

    {:noreply, state}
  end

  def handle_cast({:outgoing, packet}, state = %{seq: seq}) do
    :telemetry.span([:gen_dap, :buffer, :outgoing], %{kind: :async}, fn ->
      :ok =
        state.comm.write(
          @json_module.encode_to_iodata!(packet |> Map.put("seq", seq)),
          state.comm_data
        )

      {:ok, %{}}
    end)

    {:noreply, %{state | seq: seq + 1}}
  end

  def handle_cast({:listen, dap}, state) do
    read(state.comm, state.comm_data)

    {:noreply, Map.put(state, :dap, dap)}
  end

  @impl true
  def handle_info({:update_comm_data, comm_data}, state) do
    {:noreply, %{state | comm_data: comm_data}}
  end

  defp read(comm, comm_data) do
    me = self()

    Task.start_link(fn ->
      {:ok, comm_data} = comm.listen(comm_data)
      send(me, {:update_comm_data, comm_data})

      Stream.resource(
        fn -> "" end,
        fn buffer ->
          case comm.read(comm_data, buffer) do
            :eof ->
              if Application.get_env(:gen_dap, :exit_on_end, true) do
                System.stop()
              end

              {:halt, :ok}

            {:error, reason} ->
              {:halt, {:error, reason}}

            {:ok, body, buffer} ->
              incoming(me, body)

              {[body], buffer}
          end
        end,
        fn
          {:error, reason} ->
            IO.warn("Unable to read from device: #{inspect(reason)}")

          _ ->
            :ok
        end
      )
      |> Enum.to_list()
    end)
  end

  @doc false
  def log(message) do
    Logger.debug(message)
  end
end
