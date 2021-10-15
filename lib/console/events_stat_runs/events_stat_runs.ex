defmodule Console.EventsStatRuns do
  import Ecto.Query, warn: false
  alias Console.Repo

  alias Console.EventsStatRuns.EventsStatRun

  def create_events_stat_run(attrs \\ %{}) do
    %EventsStatRun{}
    |> EventsStatRun.changeset(attrs)
    |> Repo.insert()
  end
end
