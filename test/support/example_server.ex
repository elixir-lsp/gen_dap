defmodule GenDAPTest.ExampleServer do
  use GenDAP

  alias GenDAP.Requests
  alias GenDAP.Events
  alias GenDAP.Structures

  def start_link(opts) do
    {test_pid, opts} = Keyword.pop(opts, :test_pid)
    GenDAP.start_link(__MODULE__, test_pid, opts)
  end

  @impl true
  def init(dap, test_pid) do
    {:ok, assign(dap, foo: :bar, test_pid: test_pid)}
  end

  @impl true
  def handle_request(%Requests.InitializeRequest{} = request, dap) do
    {:reply,
     %Requests.InitializeResponse{
       request_seq: request.seq,
       seq: 0,
       body: %Structures.Capabilities{
         supports_cancel_request: true
       }
     }, dap}
  end

  def handle_request(%Requests.PauseRequest{} = request, dap) do
    GenDAP.notify(dap, %Events.ThreadEvent{
      body: %{
        reason: "pause",
        thread_id: request.arguments.thread_id
      },
      seq: 0
    })

    {:reply,
     %Requests.PauseResponse{
       request_seq: request.seq,
       seq: 0
     }, dap}
  end

  def handle_request(%Requests.ContinueRequest{} = request, dap) do
    result =
      GenDAP.request(dap, %GenDAP.Requests.RunInTerminalRequest{
        seq: 0,
        arguments: %GenDAP.Structures.RunInTerminalRequestArguments{
          cwd: ".",
          args: ["elixir", "--sname", "example_server", "--cookie", "example_cookie"]
        }
      })

    send(dap.assigns.test_pid, result)

    {:reply,
     %Requests.ContinueResponse{
       request_seq: request.seq,
       seq: 0,
       body: %{all_threads_continued: true}
     }, dap}
  end

  def handle_request(
        %Requests.StackTraceRequest{
          arguments: %Structures.StackTraceArguments{thread_id: thread_id}
        } = request,
        dap
      ) do
    case thread_id do
      1 ->
        # invalid value
        {:reply, [], dap}

      2 ->
        # wrong type
        {:reply,
         %Requests.TerminateThreadsResponse{
           request_seq: request.seq,
           seq: 0
         }, dap}

      3 ->
        # correct type, missing required
        {:reply,
         %Requests.StackTraceResponse{
           request_seq: request.seq,
           seq: 0,
           body: %{}
         }, dap}

      4 ->
        # invalid error response missing required
        {:reply,
         %GenDAP.Structures.ErrorResponse{
           request_seq: request.seq,
           message: "boom",
           type: "response",
           success: false,
           command: request.command,
           seq: 0,
           body: %{
             error: %{}
           }
         }, dap}
    end
  end

  def handle_request(%Requests.TerminateThreadsRequest{}, dap) do
    raise "boom"
    {:reply, [], dap}
  end

  def handle_request(
        %Requests.EvaluateRequest{
          seq: seq,
          arguments: %Structures.EvaluateArguments{expression: expression}
        },
        dap
      ) do
    callback = fn ->
      Process.sleep(String.to_integer(expression))

      %Requests.EvaluateResponse{
        request_seq: seq,
        seq: 0,
        body: %{result: "1", variables_reference: 1}
      }
    end

    {:async_reply, callback, dap}
  end

  def handle_request(request, dap) do
    {:reply,
     %GenDAP.Structures.ErrorResponse{
       request_seq: request.seq,
       command: request.command,
       seq: 0,
       message: "Not implemented",
       success: false,
       type: "response",
       body: %{}
     }, dap}
  end

  @impl true
  def handle_info(:boom, dap) do
    raise "boom"
    {:noreply, dap}
  end

  # def handle_info({:evaluate, seq, result}, dap) do
  #   {:reply,
  #    %Requests.EvaluateResponse{
  #      request_seq: seq,
  #      seq: 0,
  #      body: %{result: result}
  #    }, dap}
  # end

  def handle_info(_message, dap) do
    send(dap.assigns.test_pid, {:info, :ack})
    {:noreply, dap}
  end
end
