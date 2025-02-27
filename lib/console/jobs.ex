defmodule Console.Jobs do
  # This module defines the jobs to be ran by Quantum scheduler
  # as defined in config/config.exs

  alias Console.Email
  alias Console.Mailer
  alias Console.Organizations
  alias Console.Devices
  alias Console.Events
  alias Console.Alerts
  alias Console.AlertEvents
  alias Console.Repo
  alias Console.BlockchainApi
  alias Console.Hotspots

  def send_alerts do
    # to avoid spamming customers with multiple notifications for the same event, get notifications in 5-min batches
    now = Timex.now
    buffer = -5
    alertable_email_events = AlertEvents.get_unsent_alert_events_since("email", Timex.shift(now, minutes: buffer))
    alertable_webhook_events = AlertEvents.get_unsent_alert_events_since("webhook", Timex.shift(now, minutes: buffer))

    # send emails for this batch, grouped by event type and label
    Enum.each(Enum.group_by(alertable_email_events, &Map.take(&1, [:alert_id, :event])), fn {identifiers, events} ->
      Task.Supervisor.async_nolink(ConsoleWeb.TaskSupervisor, fn ->
        send_specific_event_email(identifiers, events)
      end)
    end)

    Enum.each(Enum.group_by(alertable_webhook_events, &Map.take(&1, [:alert_id, :event])), fn {identifiers, events} ->
      Task.Supervisor.async_nolink(ConsoleWeb.TaskSupervisor, fn ->
        send_webhook(identifiers, events)
      end)
    end)
  end

  defp send_specific_event_email(identifiers, events) do
    alert = Alerts.get_alert(identifiers.alert_id)
    alert_event_email_config = alert.config[identifiers.event]["email"]

    # continue w/ email if the setting for the specific label
    if alert_event_email_config != nil do
      # based on settings, prepare info needed for email
      organization = Organizations.get_organization(alert.organization_id)
      roles = case alert_event_email_config["recipient"] do
        "admin" -> ["admin"]
        "manager" -> ["manager"]
        "read" -> ["read"]
        "all" -> ["admin", "manager", "read"]
      end
      recipients = Organizations.get_memberships_by_organization_and_role(alert.organization_id, roles) |> Enum.map(fn (member) -> member.email end)
      details = Enum.map(events, fn (e) -> e.details end)
      has_hotspot_info = case Enum.find(details, fn d -> d["hotspot"] !== nil and length(Map.keys(d["hotspot"])) > 0 end) do
        nil -> false
        _ -> true
      end

      # send email specific to the type of event
      case identifiers.event do
        "device_deleted" -> Email.device_deleted_notification_email(recipients, alert.name, details, organization.name, alert.id) |> Mailer.deliver_later()
        "integration_with_devices_deleted" -> Email.integration_with_devices_deleted_notification_email(recipients, alert.name, details, organization.name, alert.id) |> Mailer.deliver_later()
        "integration_with_devices_updated" -> Email.integration_with_devices_updated_notification_email(recipients, alert.name, details, organization.name, alert.id) |> Mailer.deliver_later()
        "device_join_otaa_first_time" -> Email.device_join_otaa_first_time_notification_email(recipients, alert.name, details, organization.name, alert.id, has_hotspot_info) |> Mailer.deliver_later()
        "integration_stops_working" -> Email.integration_stops_working_notification_email(recipients, alert.name, details, organization.name, alert.id) |> Mailer.deliver_later()
        "device_stops_transmitting" -> Email.device_stops_transmitting_notification_email(recipients, alert.name, details, organization.name, alert.id, has_hotspot_info) |> Mailer.deliver_later()
        "downlink_unsuccessful" -> Email.downlink_unsuccessful_notification_email(recipients, alert.name, details, organization.name, alert.id) |> Mailer.deliver_later()
        "integration_receives_first_event" -> Email.integration_receives_first_event_notification_email(recipients, alert.name, details, organization.name, alert.id) |> Mailer.deliver_later()
      end

      Enum.each(events, fn e -> AlertEvents.mark_alert_event_sent(e) end)
    end
  end

  defp send_webhook(identifiers, events) do
    alert = Alerts.get_alert(identifiers.alert_id)
    alert_event_webhook_config = alert.config[identifiers.event]["webhook"]

    if alert_event_webhook_config != nil do
      organization = Organizations.get_organization(alert.organization_id)

      # sanitize events by removing __meta__ field which causes JSON serializing differences on request end
      sanitized_events = Enum.map(events, fn e -> Map.delete(Map.from_struct(e), :__meta__) end)

      payload = Poison.encode!(sanitized_events)
      headers = [
        {"X-Helium-Hmac-SHA256", :crypto.hmac(:sha256, organization.webhook_key, payload) |> Base.encode64(padding: true)},
        {"Content-Type", "application/json"}
      ]
      HTTPoison.post(alert_event_webhook_config["url"], payload, headers)
      Enum.each(events, fn e -> AlertEvents.mark_alert_event_sent(e) end)
    end
  end

  def delete_sent_alerts do
    # since events are kept as "sent" so we can check against flapping, delete them in 25-hr batches, 24 + 1 to delete alerts triggered in last 5 min before reset
    buffer = -25
    AlertEvents.delete_sent_alert_events_since(Timex.shift(Timex.now, hours: buffer))
  end

  def trigger_device_stops_transmitting do
    alerts = Alerts.get_alerts_by_event("device_stops_transmitting") |> Repo.preload([:alert_nodes])

    Enum.each(alerts, fn alert ->
      alert_nodes = alert.alert_nodes

      # value in the config determines period of time to check if device stopped connecting
      email_config_value = alert.config["device_stops_transmitting"]["email"]["value"]
      webhook_config_value = alert.config["device_stops_transmitting"]["webhook"]["value"]

      Enum.each(alert_nodes, fn an ->
        if email_config_value != nil do
          buffer = email_config_value
          Task.Supervisor.async_nolink(ConsoleWeb.TaskSupervisor, fn ->
            check_device_stop_transmitting(an.node_id, an.node_type, Timex.shift(Timex.now, minutes: -buffer), buffer)
          end)
        end

        if webhook_config_value != nil && webhook_config_value != email_config_value do
          buffer = webhook_config_value
          Task.Supervisor.async_nolink(ConsoleWeb.TaskSupervisor, fn ->
            check_device_stop_transmitting(an.node_id, an.node_type, Timex.shift(Timex.now, minutes: -buffer), buffer)
          end)
        end
      end)
    end)
  end

  defp check_device_stop_transmitting(node_id, node_type, starting_from, buffer) do
    devices =
      case node_type do
        "device" ->
          [Devices.get_device(node_id)]
        "label" ->
          Devices.get_devices_for_label(node_id)
      end

    Enum.each(devices, fn device ->
      if device.active and device.last_connected != nil and Timex.compare(device.last_connected, starting_from) == -1 do
        event = Events.get_device_last_event(device.id)
        { _, last_connected_time } = Timex.format(device.last_connected, "%m/%d/%y %H:%M:%S UTC", :strftime)
        details = %{
          device_name: device.name,
          device_id: device.id,
          time: last_connected_time,
          hotspot: case event != nil and event.data["hotspot"] != nil do
            false -> nil
            true -> event.data["hotspot"]
          end,
          buffer: buffer
        }

        limit = %{ time_buffer: Timex.shift(Timex.now, hours: -24) }

        case node_type do
          "device" ->
            AlertEvents.notify_alert_event(device.id, "device", "device_stops_transmitting", details, nil, limit)
          "label" ->
            AlertEvents.notify_alert_event(device.id, "device", "device_stops_transmitting", details, [node_id], limit)
        end
      end
    end)
  end

  def sync_hotspots() do
    case BlockchainApi.each_page("/hotspots", &process_hotspots/1) do
      :ok ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  defp process_hotspots(hotspots) do
    hotspots
    |> Enum.map(&sanitize/1)
    |> Enum.each(&upsert_hotspot/1)
  end

  @fields [
    :address,
    :lat,
    :lng,
    :location,
    :name,
    :status,
    :height,
    :short_state,
    :short_country,
    :long_city,
    :owner
  ]

  defp sanitize(hotspot) do
    hotspot
    |> Map.put("status", hotspot["status"]["online"])
    |> Map.put("height", hotspot["status"]["height"])
    |> Map.put("short_state", hotspot["geocode"]["short_state"])
    |> Map.put("short_country", hotspot["geocode"]["short_country"])
    |> Map.put("long_city", hotspot["geocode"]["long_city"])
    |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)
    |> Map.take(@fields)
  end

  defp upsert_hotspot(%{address: address} = params) do
    hotspot = Hotspots.get_hotspot(address)

    if hotspot == nil do
      Hotspots.create_hotspot(params)
    else
      Hotspots.update_hotspot(hotspot, params)
    end
  end
end
