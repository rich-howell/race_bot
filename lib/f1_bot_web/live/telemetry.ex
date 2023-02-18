defmodule F1BotWeb.Live.Telemetry do
  use F1BotWeb, :live_view
  alias F1BotWeb.Component

  data session_clock, :any, default: nil
  data session_info, :any, default: nil
  data driver_list, :list, default: []
  data lap_counter, :map, default: nil
  data drivers_of_interest, :list, default: [1, 11, 16, 55, 44, 63]

  def mount(_params, session, socket) do
    initial_delay = 1_000

    socket =
      socket
      |> subscribe_to_own_events(session)
      |> subscribe_with_delay(initial_delay)

    {:ok, socket}
  end

  def pubsub_topics do
    [
      {:driver, :list},
      {:lap_counter, :changed},
      {:session_info, :session_info_changed},
      {:session_clock, :changed}
    ]
  end

  def pubsub_per_driver_topics(driver_numbers) do
    for driver_no <- driver_numbers do
      [
        {:"driver:#{driver_no}", :summary}
      ]
    end
    |> List.flatten()
  end

  def pubsub_oneshot_topics do
    [
      {:chart_init, :lap_times}
    ]
  end

  def pubsub_delta_topics do
    [
      {:chart_insert, :lap_times},
      {:chart_replace, :track_status}
    ]
  end

  @impl true
  def handle_event("toggle-driver", params, socket) do
    driver_no = String.to_integer(params["driver-number"])
    is_doi = driver_no in socket.assigns.drivers_of_interest

    drivers_of_interest =
      if is_doi do
        Enum.reject(socket.assigns.drivers_of_interest, &(&1 == driver_no))
      else
        [driver_no | socket.assigns.drivers_of_interest]
      end

    socket =
      socket
      |> assign(:drivers_of_interest, drivers_of_interest)
      |> subscribe_with_delay()

    {:noreply, socket}
  end

  @impl true
  def handle_info(
        {:delay_control_set, delay_ms},
        socket
      ) do
    # Broadcast event for all LiveViews to synchronize delay across tabs/windows
    broadcast_own_event(socket.assigns.user_uuid, {:user_set_delay_ms, delay_ms})
    {:noreply, socket}
  end

  @impl true
  def handle_info(
        {:user_set_delay_ms, delay_ms},
        socket
      ) do
    # Handle broadcasted delay control event to synchronize all tabs/windows
    socket = subscribe_with_delay(socket, delay_ms)
    {:noreply, socket}
  end

  @impl true
  def handle_info(e = %{type: :summary}, socket) do
    Component.DriverSummary.handle_summary_event(e)
    {:noreply, socket}
  end

  @impl true
  def handle_info(
        %{scope: :driver, type: :list, payload: driver_list},
        socket
      ) do
    socket = assign(socket, driver_list: driver_list)
    {:noreply, socket}
  end

  @impl true
  def handle_info(
        %{scope: :lap_counter, type: :changed, payload: lap_counter},
        socket
      ) do
    lap_counter = Map.delete(lap_counter, :__struct__)
    socket = assign(socket, lap_counter: lap_counter)
    {:noreply, socket}
  end

  @impl true
  def handle_info(
        %{scope: :session_clock, type: :changed, payload: session_clock},
        socket
      ) do
    socket = assign(socket, session_clock: session_clock)
    {:noreply, socket}
  end

  @impl true
  def handle_info(
        %{scope: :session_info, type: :session_info_changed, payload: session_info},
        socket
      ) do
    socket = assign(socket, session_info: session_info)
    {:noreply, socket}
  end

  @impl true
  def handle_info(
        %{scope: :chart_init, type: id, payload: spec},
        socket
      ) do
    socket = Component.VegaChart.initialize(socket, id, spec)
    {:noreply, socket}
  end

  @impl true
  def handle_info(
        %{scope: :chart_insert, type: id, payload: %{dataset: dataset, data: data}},
        socket
      ) do
    socket = Component.VegaChart.insert_data(socket, id, dataset, data)
    {:noreply, socket}
  end

  @impl true
  def handle_info(
        %{scope: :chart_replace, type: id, payload: %{dataset: dataset, data: data}},
        socket
      ) do
    socket = Component.VegaChart.replace_data(socket, id, dataset, data)
    {:noreply, socket}
  end

  defp subscribe_with_delay(socket, delay_ms \\ nil) do
    delay_ms =
      if delay_ms == nil do
        socket.assigns.pubsub_delay_ms
      else
        delay_ms
      end

    existing_topics = socket.assigns[:pubsub_delayed_topics]

    if existing_topics do
      F1Bot.PubSub.unsubscribe_all(existing_topics)
    end

    global_topics = pubsub_topics()
    per_driver_topics = pubsub_per_driver_topics(socket.assigns.drivers_of_interest)
    topics_to_subscribe = global_topics ++ per_driver_topics

    F1Bot.DelayedEvents.oneshot_init(pubsub_oneshot_topics(), delay_ms)

    {:ok, subscribed_topics} =
      F1Bot.DelayedEvents.subscribe_with_delay(
        topics_to_subscribe,
        delay_ms,
        true
      )

    {:ok, subscribed_delta_topics} =
      F1Bot.DelayedEvents.subscribe_with_delay(
        pubsub_delta_topics(),
        delay_ms,
        false
      )

    all_subscribed_topics = subscribed_topics ++ subscribed_delta_topics

    socket
    |> assign(:pubsub_delay_ms, delay_ms)
    |> assign(:pubsub_delayed_topics, all_subscribed_topics)
  end

  defp is_race?(_session_info = nil), do: false
  defp is_race?(session_info), do: F1Bot.F1Session.SessionInfo.is_race?(session_info)
end
