Application.put_env(:gen_dap, :exit_on_end, false)

ExUnit.start(capture_log: true)
