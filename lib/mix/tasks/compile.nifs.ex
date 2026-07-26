defmodule Mix.Tasks.Compile.Nifs do
  use Mix.Task.Compiler

  @impl true
  def run(_args) do
    case System.cmd("make", [], stderr_to_stdout: true) do
      {result, 0} ->
        IO.binwrite(result)
        Mix.Shell.IO.info("Successfully compiled NIFs")
        {:ok, []}

      {result, exit_code} ->
        {:error, [diagnostic("make exited with #{exit_code}:\n#{result}")]}
    end
  rescue
    err ->
      # e.g. `make` not on PATH.
      {:error, [diagnostic("Failed to run make: #{inspect(err)}")]}
  end

  defp diagnostic(message) do
    %Mix.Task.Compiler.Diagnostic{
      compiler_name: "nifs",
      file: Path.absname("Makefile"),
      message: message,
      position: 0,
      severity: :error
    }
  end
end
