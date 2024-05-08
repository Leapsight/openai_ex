defmodule OpenaiEx.HttpSse do
  @moduledoc false
  alias OpenaiEx.Http
  require Logger

  # based on
  # https://gist.github.com/zachallaun/88aed2a0cef0aed6d68dcc7c12531649

  @doc false
  def post(openai = %OpenaiEx{}, url, json: json) do
    request = OpenaiEx.Http.build_post(openai, url, json: json)
    http_opts = Http.request_options(openai)
    connect_timeout = Keyword.get(http_opts, :connect_timeout, 8_000)
    me = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        on_chunk = create_chunk_handler(me, ref)

        result =
          request
          |> Finch.stream(
            Map.get(openai, :finch_name),
            nil,
            on_chunk,
            http_opts
          )

        case result do
          {:ok, _} ->
            send(me, {:done, ref})

          {:error, reason} ->
            # A connection error
            send(me, {:error, reason, ref})
        end
      end)

    await_response(openai, task, ref, connect_timeout, %{task_pid: task.pid})
  end

  @doc false
  def cancel_request(task_pid) when is_pid(task_pid) do
    send(task_pid, :cancel_request)
  end

  @doc false
  defp create_chunk_handler(me, ref) do
    fn chunk, _acc ->
      receive do
        :cancel_request ->
          send(me, {:canceled, ref})
          exit(:normal)
      after
        0 -> send(me, {:chunk, chunk, ref})
      end
    end
  end

  defp await_response(openai, task, ref, timeout, acc) do
    receive do
      {:error, reason, ^ref} ->
        Task.shutdown(task)
        raise reason

      {:chunk, {:status, status}, ^ref} ->
        await_response(openai, task, ref, timeout, Map.put(acc, :status, status))

      {:chunk, {:headers, headers}, ^ref} ->
        stream_timeout = Map.get(openai, :stream_timeout, :infinity)
        :timer.apply_after(3000, __MODULE__, :cancel_request, [task.pid])

        body_stream =
          Stream.resource(
            fn -> {"", ref, task, stream_timeout} end,
            &next_sse/1,
            fn {_data, _ref, task, _} -> Task.shutdown(task) end
          )

        acc
        |> Map.put(:headers, headers)
        |> Map.put(:body_stream, body_stream)
    after
      timeout ->
        Task.shutdown(task)
        throw(:connect_timeout)
    end
  end

  @doc false
  defp next_sse({_, _, _, -1} = term) do
    {:halt, term}
  end

  defp next_sse({acc, ref, task, timeout}) do
    receive do
      {:chunk, {:data, evt_data}, ^ref} ->
        {tokens, next_acc} = tokenize_data(evt_data, acc)
        {[tokens], {next_acc, ref, task, timeout}}

      {:canceled, ^ref} ->
        Logger.debug("Request canceled by user")
        tokens = [%{data: "[CANCELED]"}]
        {[tokens], {acc, ref, task, -1}}

      {:done, ^ref} when acc == "data: [DONE]" ->
        {:halt, {acc, ref, task, timeout}}

      {:done, ^ref} ->
        if acc != "",
          do:
            Logger.warning(%{
              message: "Unexpected value in sse 'acc' after ':done' event received",
              value: acc
            })

        {:halt, {acc, ref, task, timeout}}
    after
      timeout ->
        exit({:timeout, timeout})
    end
  end

  @double_eol ~r/(\r?\n|\r){2}/

  @doc false
  defp tokenize_data(evt_data, acc) do
    all_data = acc <> evt_data

    if Regex.match?(@double_eol, evt_data) do
      {remaining, token_chunks} = all_data |> String.split(@double_eol) |> List.pop_at(-1)

      tokens =
        token_chunks
        |> Enum.map(&extract_token/1)
        |> Enum.filter(fn
          %{data: "[DONE]"} -> true
          %{data: "[CANCELED]"} -> true
          %{data: _} -> true
          # we can pass other events through but the clients will need to be rewritten
          _ -> false
        end)

      {tokens, remaining}
    else
      {[], all_data}
    end
  end

  defp extract_token(line) do
    [field | rest] = String.split(line, ":", parts: 2)
    value = Enum.join(rest, "") |> String.replace_prefix(" ", "")

    case field do
      "data" -> %{data: Jason.decode!(value)}
      "event" -> %{eventType: value}
      "id" -> %{lastEventId: value}
      "retry" -> %{retry: value}
      # comment
      _ -> nil
    end
  end
end
