defmodule CleatDeploy.Repo.Migrations.AddTraceSpansAndSampleRate do
  use Ecto.Migration

  def change do
    alter table(:apps) do
      add :trace_sample_rate, :float, null: false, default: 0.0
    end

    create table(:trace_spans) do
      add :tenant_id, references(:tenants, on_delete: :delete_all), null: false
      add :app_id, references(:apps, on_delete: :delete_all), null: false
      add :trace_id, :string, null: false
      add :span_id, :string, null: false
      add :parent_span_id, :string, null: false, default: ""
      add :name, :string, null: false, default: ""
      add :kind, :string, null: false, default: "unspecified"
      add :service_name, :string, null: false, default: ""
      add :status_code, :string, null: false, default: "unset"
      add :start_time_unix_nano, :integer, null: false, default: 0
      add :end_time_unix_nano, :integer, null: false, default: 0
      add :duration_ns, :integer, null: false, default: 0
      add :attributes, :map, null: false, default: %{}

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:trace_spans, [:tenant_id, :trace_id, :span_id])
    create index(:trace_spans, [:app_id, :start_time_unix_nano])
    create index(:trace_spans, [:tenant_id, :trace_id])
  end
end
