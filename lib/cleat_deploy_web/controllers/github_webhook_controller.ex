defmodule CleatDeployWeb.GithubWebhookController do
  use CleatDeployWeb, :controller

  require Logger

  alias CleatDeploy.{Apps, Deployments, Github}

  def create(conn, _params) do
    raw_body = conn.private[:raw_body] || ""
    signature = get_req_header(conn, "x-hub-signature-256") |> List.first()

    result =
      with {:ok, payload} <- decode_payload(raw_body),
           repo when is_binary(repo) <- Github.repo_full_name(payload) || :missing_repo,
           {:ok, apps} <- find_repo_apps(repo, raw_body, signature),
           {:ok, {ref, sha}} <- Github.push_ref(payload) do
        handle_push(apps, ref, sha)
      end

    respond(conn, result)
  end

  defp respond(conn, {:queued, queued}) do
    Enum.each(queued, fn {app, job} ->
      Logger.info(
        "github webhook queued deploy app=#{app.slug} job=#{job.id} repo=#{app.github_repo} ref=#{app.branch}"
      )
    end)

    send_resp(conn, :accepted, "queued")
  end

  defp respond(conn, {:ignored, apps, ref}) do
    branches = apps |> Enum.map(& &1.branch) |> Enum.uniq() |> Enum.join(", ")

    Logger.info("github webhook ignored ref=#{ref} instances_deploy=#{branches}")

    send_resp(conn, :ok, "ignored: push to #{ref}, instances deploy #{branches}")
  end

  defp respond(conn, {:auto_deploy_off, apps}) do
    Logger.info("github webhook auto_deploy disabled for #{length(apps)} instance(s)")
    send_resp(conn, :ok, "auto deploy disabled")
  end

  defp respond(conn, {:enqueue_failed, failed}) do
    Enum.each(failed, fn {app, reason} ->
      Logger.error("github webhook enqueue failed app=#{app.slug}: #{inspect(reason)}")
    end)

    send_resp(conn, :bad_request, "enqueue failed")
  end

  defp respond(conn, :not_found) do
    Logger.warning("github webhook unknown repo")
    send_resp(conn, :not_found, "unknown repo")
  end

  defp respond(conn, :missing_repo) do
    Logger.warning("github webhook payload missing repository.full_name")
    send_resp(conn, :bad_request, "missing repository")
  end

  defp respond(conn, :error) do
    Logger.warning("github webhook invalid signature")
    send_resp(conn, :unauthorized, "invalid signature")
  end

  defp respond(conn, {:ignore, reason}) do
    Logger.info("github webhook ignored push: #{inspect(reason)}")
    send_resp(conn, :ok, "ignored")
  end

  defp respond(conn, {:error, reason}) do
    Logger.error("github webhook invalid payload: #{inspect(reason)}")
    send_resp(conn, :bad_request, "invalid payload")
  end

  # Every instance of the repository that deploys the pushed branch is queued, so
  # a push to `staging` reaches the staging instance only.
  defp handle_push(apps, ref, sha) do
    attrs = %{git_sha: sha, git_ref: ref, triggered_by: "webhook"}

    {queued, failed} =
      apps
      |> Enum.filter(&(&1.branch == ref and &1.auto_deploy))
      |> Enum.reduce({[], []}, fn app, {queued, failed} ->
        case Deployments.enqueue(app, attrs) do
          {:ok, job} -> {[{app, job} | queued], failed}
          {:error, reason} -> {queued, [{app, reason} | failed]}
        end
      end)

    cond do
      queued != [] -> {:queued, Enum.reverse(queued)}
      failed != [] -> {:enqueue_failed, Enum.reverse(failed)}
      Enum.any?(apps, &(&1.branch == ref)) -> {:auto_deploy_off, apps}
      true -> {:ignored, apps, ref}
    end
  end

  # The push hook lives on the repository, not on the app, so any instance of
  # that repo that validates the signature authenticates the payload.
  defp find_repo_apps(repo, raw_body, signature) do
    apps = Apps.list_apps_by_repo(repo)

    cond do
      apps == [] ->
        :not_found

      signature in [nil, ""] ->
        :error

      true ->
        verified? =
          Enum.any?(apps, fn app ->
            Github.verify_signature(raw_body, signature, app.webhook_secret) == :ok
          end)

        if verified?, do: {:ok, apps}, else: :error
    end
  end

  defp decode_payload(raw_body) when is_binary(raw_body) and raw_body != "" do
    case Jason.decode(raw_body) do
      {:ok, payload} -> {:ok, payload}
      _ -> {:error, :invalid_json}
    end
  end

  defp decode_payload(_), do: {:error, :empty_body}
end
