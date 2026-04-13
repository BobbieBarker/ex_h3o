defmodule ExH3oShutdownTest do
  use ExUnit.Case, async: true

  @collect_timeout_ms 10_000

  describe "ERL_NIF_OPT_DELAY_HALT" do
    test "dirty NIF completes during VM shutdown" do
      # Spawn a child BEAM that:
      #   1. Starts a dirty NIF sleeping 500ms
      #   2. Calls init:stop/0 after 50ms
      #   3. Prints "nif_completed" when the NIF returns
      #
      # With DELAY_HALT the dirty NIF finishes before halt proceeds,
      # so we see "nif_completed" in stdout. Without the flag the
      # process is killed mid-sleep and the message never appears.

      erl = System.find_executable("erl")

      nif_so_dir =
        :ex_h3o
        |> :code.priv_dir()
        |> List.to_string()
        |> Path.join("native")

      assert File.dir?(nif_so_dir)

      # Pass NIF .so directory and ebin paths via -pa flags to avoid
      # string interpolation issues with special characters in paths.
      code = """
      spawn(fun() ->
        'Elixir.ExH3o.Native':dirty_sleep(500),
        io:format("nif_completed~n")
      end),
      timer:sleep(50),
      init:stop(),
      timer:sleep(2000).
      """

      pa_dirs = [nif_so_dir | ebin_paths()]

      args =
        Enum.flat_map(pa_dirs, &["-pa", &1]) ++ ["-noshell", "-eval", code]

      port =
        Port.open({:spawn_executable, erl}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: args
        ])

      {output, exit_status} = collect_port_output(port, <<>>, @collect_timeout_ms)

      refute exit_status == :timeout,
             "child BEAM did not exit within #{@collect_timeout_ms}ms"

      assert 0 = exit_status
      assert output =~ "nif_completed", "dirty NIF did not complete before VM halt"
    end
  end

  defp collect_port_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, acc <> data, timeout)

      {^port, {:exit_status, status}} ->
        {acc, status}
    after
      timeout ->
        {acc, :timeout}
    end
  end

  defp ebin_paths do
    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.filter(&String.ends_with?(&1, "/ebin"))
  end
end
