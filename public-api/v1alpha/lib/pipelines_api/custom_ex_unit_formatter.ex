defmodule PipelinesAPI.CustomExUnitFormatter do
  @moduledoc false
  use GenServer

  import ExUnit.Formatter,
    only: [format_times: 1, format_filters: 2, format_test_failure: 5, format_test_all_failure: 5]

  ## Callbacks

  def init(opts) do
    print_filters(Keyword.take(opts, [:include, :exclude]))

    config = %{
      seed: opts[:seed],
      trace: opts[:trace],
      colors: colors(opts),
      width: get_terminal_width(),
      slowest: opts[:slowest],
      test_counter: %{},
      test_timings: [],
      failure_counter: 0,
      skipped_counter: 0,
      excluded_counter: 0,
      invalid_counter: 0,
      summary_failures: [],
      summary_invalids: []
    }

    {:ok, config}
  end

  def handle_cast({:suite_started, _opts}, config) do
    {:noreply, config}
  end

  def handle_cast({:suite_finished, times_us}, config) do
    IO.write("\n\n")
    IO.puts(format_times(times_us))

    if config.slowest > 0 do
      IO.write("\n")
      IO.puts(format_slowest_total(config, times_us.run))
      IO.puts(format_slowest_times(config))
    end

    print_summary(config, false)
    {:noreply, config}
  end

  def handle_cast({:test_started, %ExUnit.Test{} = test}, config) do
    if config.trace, do: IO.write("#{trace_test_started(test)} [#{trace_test_line(test)}]")
    {:noreply, config}
  end

  def handle_cast({:test_finished, %ExUnit.Test{state: nil} = test}, config) do
    if config.trace do
      IO.puts(success(trace_test_result(test), config))
    else
      IO.write(success(".", config))
    end

    test_counter = update_test_counter(config.test_counter, test)
    test_timings = update_test_timings(config.test_timings, test)
    config = %{config | test_counter: test_counter, test_timings: test_timings}

    {:noreply, config}
  end

  def handle_cast({:test_finished, %ExUnit.Test{state: {:excluded, _}} = test}, config) do
    if config.trace, do: IO.puts(trace_test_excluded(test))

    test_counter = update_test_counter(config.test_counter, test)
    config = %{config | test_counter: test_counter, excluded_counter: config.excluded_counter + 1}

    {:noreply, config}
  end

  def handle_cast({:test_finished, %ExUnit.Test{state: {:skipped, _}} = test}, config) do
    if config.trace do
      IO.puts(skipped(trace_test_skipped(test), config))
    else
      IO.write(skipped("*", config))
    end

    test_counter = update_test_counter(config.test_counter, test)
    config = %{config | test_counter: test_counter, skipped_counter: config.skipped_counter + 1}

    {:noreply, config}
  end

  def handle_cast({:test_finished, %ExUnit.Test{state: {:invalid, _}} = test}, config) do
    if config.trace do
      IO.puts(invalid(trace_test_result(test), config))
    else
      IO.write(invalid("?", config))
    end

    formatted = invalid(format_invalid_test(test), config)
    summary_invalids = config.summary_invalids ++ [formatted]

    test_counter = update_test_counter(config.test_counter, test)

    config = %{
      config
      | test_counter: test_counter,
        invalid_counter: config.invalid_counter + 1,
        summary_invalids: summary_invalids
    }

    {:noreply, config}
  end

  def handle_cast({:test_finished, %ExUnit.Test{state: {:failed, failures}} = test}, config) do
    if config.trace do
      IO.puts(failure(trace_test_result(test), config))
    end

    formatted =
      format_test_failure(
        test,
        failures,
        config.failure_counter + 1,
        config.width,
        &formatter(&1, &2, config)
      )

    print_failure(formatted, config)
    print_logs(test.logs)

    summary_failures = config.summary_failures ++ [formatted]

    test_counter = update_test_counter(config.test_counter, test)
    test_timings = update_test_timings(config.test_timings, test)
    failure_counter = config.failure_counter + 1

    config = %{
      config
      | test_counter: test_counter,
        test_timings: test_timings,
        failure_counter: failure_counter,
        summary_failures: summary_failures
    }

    {:noreply, config}
  end

  def handle_cast({:module_started, %ExUnit.TestModule{name: name, file: file}}, config) do
    if config.trace() do
      IO.puts("\n#{inspect(name)} [#{Path.relative_to_cwd(file)}]")
    end

    {:noreply, config}
  end

  def handle_cast({:module_finished, %ExUnit.TestModule{state: nil}}, config) do
    {:noreply, config}
  end

  def handle_cast(
        {:module_finished, %ExUnit.TestModule{state: {:failed, failures}} = test_module},
        config
      ) do
    # The failed tests have already contributed to the counter,
    # so we should only add the successful tests to the count
    config =
      update_in(config.failure_counter, fn counter ->
        counter + Enum.count(test_module.tests, &is_nil(&1.state))
      end)

    formatted =
      format_test_all_failure(
        test_module,
        failures,
        config.failure_counter,
        config.width,
        &formatter(&1, &2, config)
      )

    print_failure(formatted, config)

    test_counter =
      Enum.reduce(test_module.tests, config.test_counter, &update_test_counter(&2, &1))

    config = %{config | test_counter: test_counter}

    {:noreply, config}
  end

  def handle_cast(:max_failures_reached, config) do
    IO.write(failure("--max-failures reached, aborting test suite", config))
    {:noreply, config}
  end

  def handle_cast({:sigquit, current}, config) do
    IO.write("\n\n")

    if current == [] do
      IO.write(failure("Aborting test suite, showing results so far...\n\n", config))
    else
      IO.write(failure("Aborting test suite, the following have not completed:\n\n", config))
      Enum.each(current, &IO.puts(trace_aborted(&1)))
      IO.write(failure("\nShowing results so far...\n\n", config))
    end

    print_summary(config, true)
    {:noreply, config}
  end

  def handle_cast(_, config) do
    {:noreply, config}
  end

  ## Summaries

  defp format_invalid_test(test) do
    "\r  * #{test.module} - #{test.name} (#{trace_test_time(test)})\n" <>
      "\r    #{Path.relative_to_cwd(test.tags[:file])}:#{test.tags[:line]}"
  end

  ## Tracing

  defp trace_test_time(%ExUnit.Test{time: time}) do
    "#{format_us(time)}ms"
  end

  defp trace_test_line(%ExUnit.Test{tags: tags}) do
    "L##{tags.line}"
  end

  defp trace_test_file_line(%ExUnit.Test{tags: tags}) do
    "#{Path.relative_to_cwd(tags.file)}:#{tags.line}"
  end

  defp trace_test_started(test) do
    "  * #{test.name}"
  end

  defp trace_test_result(test) do
    "\r#{trace_test_started(test)} (#{trace_test_time(test)}) [#{trace_test_line(test)}]"
  end

  defp trace_test_excluded(test) do
    "\r#{trace_test_started(test)} (excluded) [#{trace_test_line(test)}]"
  end

  defp trace_test_skipped(test) do
    "\r#{trace_test_started(test)} (skipped) [#{trace_test_line(test)}]"
  end

  defp trace_aborted(test = %ExUnit.Test{}) do
    "* #{test.name} [#{trace_test_file_line(test)}]"
  end

  defp trace_aborted(%ExUnit.TestModule{name: name, file: file}) do
    "* #{inspect(name)} [#{Path.relative_to_cwd(file)}]"
  end

  defp normalize_us(us) do
    div(us, 1000)
  end

  defp format_us(us) do
    us = div(us, 10)

    if us < 10 do
      "0.0#{us}"
    else
      us = div(us, 10)
      "#{div(us, 10)}.#{rem(us, 10)}"
    end
  end

  defp update_test_counter(test_counter, %{tags: %{test_type: test_type}}) do
    Map.update(test_counter, test_type, 1, &(&1 + 1))
  end

  ## Slowest

  defp format_slowest_total(config = %{slowest: slowest}, run_us) do
    slowest_us =
      config
      |> extract_slowest_tests()
      |> Enum.reduce(0, &(&1.time + &2))

    slowest_time =
      slowest_us
      |> normalize_us()
      |> format_us()

    percentage = Float.round(slowest_us / run_us * 100, 1)

    "Top #{slowest} slowest (#{slowest_time}s), #{percentage}% of total time:\n"
  end

  defp format_slowest_times(config) do
    config
    |> extract_slowest_tests()
    |> Enum.map(&format_slow_test/1)
  end

  defp format_slow_test(test = %ExUnit.Test{time: time, module: module}) do
    "#{trace_test_started(test)} (#{inspect(module)}) (#{format_us(time)}ms) " <>
      "[#{trace_test_file_line(test)}]\n"
  end

  defp extract_slowest_tests(_config = %{slowest: slowest, test_timings: timings}) do
    timings
    |> Enum.sort_by(fn %{time: time} -> -time end)
    |> Enum.take(slowest)
  end

  defp update_test_timings(timings, test = %ExUnit.Test{}) do
    [test | timings]
  end

  ## Printing

  defp print_summary(config, force_failures?) do
    test_type_counts = format_test_type_counts(config)
    failure_pl = pluralize(config.failure_counter, "failure", "failures")

    message =
      "#{test_type_counts}#{config.failure_counter} #{failure_pl}"
      |> if_true(
        config.excluded_counter > 0,
        &(&1 <> ", #{config.excluded_counter} excluded")
      )
      |> if_true(
        config.invalid_counter > 0,
        &(&1 <> ", #{config.invalid_counter} invalid")
      )
      |> if_true(
        config.skipped_counter > 0,
        &(&1 <> ", " <> skipped("#{config.skipped_counter} skipped", config))
      )

    print_failures(config.summary_failures)

    print_invalids(config.summary_invalids)

    cond do
      config.failure_counter > 0 or force_failures? -> IO.puts(failure(message, config))
      config.invalid_counter > 0 -> IO.puts(invalid(message, config))
      true -> IO.puts(success(message, config))
    end

    IO.puts("\nRandomized with seed #{config.seed}")
  end

  defp print_failures(summary_failures) when length(summary_failures) > 0 do
    IO.puts("Failed tests summary:\n")

    summary_failures
    |> Enum.map(fn formatted -> IO.puts(formatted) end)
  end

  defp print_failures(_), do: :ok

  defp print_invalids(summary_invalids) when length(summary_invalids) > 0 do
    IO.puts("Invalid tests summary:\n")

    summary_invalids
    |> Enum.map(fn formatted -> IO.puts(formatted) end)
  end

  defp print_invalids(_), do: :ok

  defp if_true(value, false, _fun), do: value
  defp if_true(value, true, fun), do: fun.(value)

  defp print_filters(include: [], exclude: []) do
    :ok
  end

  defp print_filters(include: include, exclude: exclude) do
    if exclude != [], do: IO.puts(format_filters(exclude, :exclude))
    if include != [], do: IO.puts(format_filters(include, :include))
    IO.puts("")
    :ok
  end

  defp print_failure(formatted, config) do
    if config.trace do
      IO.puts("")
    else
      IO.puts("\n")
    end

    IO.puts(formatted)
  end

  defp format_test_type_counts(_config = %{test_counter: test_counter}) do
    Enum.map(test_counter, fn {test_type, count} ->
      type_pluralized = pluralize(count, test_type, ExUnit.plural_rule(test_type |> to_string()))
      "#{count} #{type_pluralized}, "
    end)
  end

  # Color styles

  defp colorize(escape, string, %{colors: colors}) do
    if colors[:enabled] do
      [escape, string, :reset]
      |> IO.ANSI.format_fragment(true)
      |> IO.iodata_to_binary()
    else
      string
    end
  end

  defp colorize_doc(escape, doc, %{colors: colors}) do
    if colors[:enabled] do
      Inspect.Algebra.color(doc, escape, %Inspect.Opts{syntax_colors: colors})
    else
      doc
    end
  end

  defp success(msg, config) do
    colorize(:green, msg, config)
  end

  defp invalid(msg, config) do
    colorize(:yellow, msg, config)
  end

  defp skipped(msg, config) do
    colorize(:yellow, msg, config)
  end

  defp failure(msg, config) do
    colorize(:red, msg, config)
  end

  defp formatter(:diff_enabled?, _, %{colors: colors}), do: colors[:enabled]

  defp formatter(:error_info, msg, config), do: colorize(:red, msg, config)

  defp formatter(:extra_info, msg, config), do: colorize(:cyan, msg, config)

  defp formatter(:location_info, msg, config), do: colorize([:bright, :black], msg, config)

  defp formatter(:diff_delete, doc, config), do: colorize_doc(:diff_delete, doc, config)

  defp formatter(:diff_delete_whitespace, doc, config),
    do: colorize_doc(:diff_delete_whitespace, doc, config)

  defp formatter(:diff_insert, doc, config), do: colorize_doc(:diff_insert, doc, config)

  defp formatter(:diff_insert_whitespace, doc, config),
    do: colorize_doc(:diff_insert_whitespace, doc, config)

  defp formatter(:blame_diff, msg, config = %{colors: colors}) do
    if colors[:enabled] do
      colorize(:red, msg, config)
    else
      "-" <> msg <> "-"
    end
  end

  defp formatter(_, msg, _config), do: msg

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_, _singular, plural), do: plural

  defp get_terminal_width do
    case :io.columns() do
      {:ok, width} -> max(40, width)
      _ -> 80
    end
  end

  @default_colors [
    diff_delete: :red,
    diff_delete_whitespace: IO.ANSI.color_background(2, 0, 0),
    diff_insert: :green,
    diff_insert_whitespace: IO.ANSI.color_background(0, 2, 0)
  ]

  defp colors(opts) do
    @default_colors
    |> Keyword.merge(opts[:colors])
    |> Keyword.put_new(:enabled, IO.ANSI.enabled?())
  end

  defp print_logs(""), do: nil

  defp print_logs(output) do
    indent = "\n     "
    output = String.replace(output, "\n", indent)
    IO.puts(["     The following output was logged:", indent | output])
  end
end
