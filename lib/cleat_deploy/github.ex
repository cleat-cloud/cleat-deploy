defmodule CleatDeploy.Github do
  @moduledoc """
  GitHub webhook verification and API helpers.

  When `GITHUB_TOKEN` is configured, the panel can list repositories and
  provision push webhooks automatically (Heroku-style) after an app is registered.
  """

  require Logger

  @github_api "https://api.github.com"

  @doc """
  Returns the webhook URL GitHub should call on push events.
  """
  def webhook_url do
    CleatDeployWeb.Endpoint.url() <> "/webhooks/github"
  end

  @doc """
  Verifies `X-Hub-Signature-256` for a raw JSON payload.
  """
  def verify_signature(raw_body, signature, secret)
      when is_binary(raw_body) and is_binary(signature) and is_binary(secret) do
    expected =
      "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, raw_body) |> Base.encode16(case: :lower))

    if Plug.Crypto.secure_compare(expected, signature) do
      :ok
    else
      :error
    end
  end

  def verify_signature(_, _, _), do: :error

  @doc """
  Parses push event payload into the branch and commit it refers to.

  Deleted refs (all-zero sha) are ignored, as are payloads that are not a branch
  push.
  """
  def push_ref(%{"ref" => "refs/heads/" <> ref, "after" => sha})
      when is_binary(sha) and sha != "" do
    if sha == String.duplicate("0", 40) do
      {:ignore, :deleted_ref}
    else
      {:ok, {ref, sha}}
    end
  end

  def push_ref(_payload), do: {:ignore, :invalid_payload}

  @doc """
  Parses push event payload and returns deploy attrs when branch matches.
  """
  def push_deploy_attrs(payload, branch \\ "main") do
    case push_ref(payload) do
      {:ok, {^branch, sha}} ->
        {:ok, %{git_sha: sha, git_ref: branch, triggered_by: "webhook"}}

      {:ok, {ref, _sha}} ->
        {:ignore, {:wrong_branch, ref}}

      {:ignore, reason} ->
        {:ignore, reason}
    end
  end

  def repo_full_name(%{"repository" => %{"full_name" => full_name}}), do: full_name
  def repo_full_name(_), do: nil

  @doc """
  Lists repositories visible to the configured GitHub token.

  Returns a list of `{full_name, full_name}` tuples sorted by name.
  """
  def list_repos do
    with {:ok, token} <- api_token(),
         {:ok, repos} <- list_repos(token, 1, []) do
      repos
    else
      {:error, :missing_token} -> []
      {:error, _reason} -> []
    end
  end

  @doc """
  Creates or updates the push webhook for an app repository.
  """
  def ensure_webhook(%{github_repo: repo, webhook_secret: secret})
      when is_binary(repo) and repo != "" and is_binary(secret) and secret != "" do
    with {:ok, token} <- api_token(),
         url <- webhook_url(),
         {:ok, hooks} <- list_hooks(repo, token),
         payload <- hook_payload(url, secret) do
      case Enum.find(hooks, &(get_in(&1, ["config", "url"]) == url)) do
        %{"id" => id} ->
          update_hook(repo, id, payload, token)

        _ ->
          create_hook(repo, payload, token)
      end
    end
  end

  def ensure_webhook(_), do: {:error, :invalid_app}

  @doc """
  Deletes the panel push webhook for an app repository, if one exists.
  """
  def delete_webhook(%{github_repo: repo}) when is_binary(repo) and repo != "" do
    with {:ok, token} <- api_token(),
         url <- webhook_url(),
         {:ok, hooks} <- list_hooks(repo, token) do
      case Enum.find(hooks, &(get_in(&1, ["config", "url"]) == url)) do
        %{"id" => id} -> delete_hook(repo, id, token)
        _ -> :ok
      end
    end
  end

  def delete_webhook(_), do: {:error, :invalid_app}

  defp list_repos(token, page, acc) do
    case api_get("/user/repos", token,
           per_page: 100,
           page: page,
           sort: "updated",
           affiliation: "owner,collaborator,organization_member"
         ) do
      {:ok, []} ->
        {:ok, sort_repo_options(acc)}

      {:ok, repos} when is_list(repos) ->
        names = Enum.map(repos, & &1["full_name"])
        list_repos(token, page + 1, acc ++ names)

      {:error, _} = error ->
        if acc == [], do: error, else: {:ok, sort_repo_options(acc)}
    end
  end

  defp sort_repo_options(names) do
    names
    |> Enum.uniq()
    |> Enum.sort_by(&String.downcase/1)
    |> Enum.map(fn name -> {name, name} end)
  end

  defp list_hooks(repo, token) do
    # `redirect: false` so a renamed/transferred repo surfaces as a 301 instead of
    # being followed silently — see `moved_repo_name/2`.
    api_get("/repos/#{repo_path(repo)}/hooks", token, [], redirect: false)
  end

  defp create_hook(repo, payload, token) do
    api_post("/repos/#{repo_path(repo)}/hooks", token, payload)
  end

  defp update_hook(repo, hook_id, payload, token) do
    api_patch("/repos/#{repo_path(repo)}/hooks/#{hook_id}", token, payload)
  end

  defp delete_hook(repo, hook_id, token) do
    request = [headers: api_headers(token)] ++ req_options()

    case Req.delete("#{@github_api}/repos/#{repo_path(repo)}/hooks/#{hook_id}", request) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, format_api_error(status, body)}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp hook_payload(url, secret) do
    %{
      "name" => "web",
      "active" => true,
      "events" => ["push"],
      "config" => %{
        "url" => url,
        "content_type" => "json",
        "secret" => secret,
        "insecure_ssl" => "0"
      }
    }
  end

  defp repo_path(repo), do: repo

  defp api_token do
    case System.get_env("GITHUB_TOKEN") do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :missing_token}
    end
  end

  defp api_get(path, token, params \\ [], options \\ []) do
    request = [headers: api_headers(token), params: params] ++ options ++ req_options()

    case Req.get("#{@github_api}#{path}", request) do
      {:ok, %{status: status} = response} when status in [301, 302, 303, 307, 308] ->
        {:error, {:repo_moved, moved_repo_name(response, token)}}

      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, format_api_error(status, body)}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  # GitHub answers `301` for a repository that was transferred or renamed. The
  # panel must not follow that silently: the app's stored `github_repo` would keep
  # looking synced while GitHub rejects every push for the stale name. The
  # redirect only carries the numeric id, so the canonical name is read from it.
  defp moved_repo_name(response, token) do
    with location when is_binary(location) <- response_header(response, "location"),
         [_, repo_id] <- Regex.run(~r{/repositories/(\d+)}, location),
         {:ok, %{"full_name" => full_name}} <- api_get("/repositories/#{repo_id}", token) do
      full_name
    else
      _ -> nil
    end
  end

  defp response_header(response, name) do
    response.headers |> Map.get(name, []) |> List.first()
  end

  defp req_options do
    Application.get_env(:cleat_deploy, :github_req_options, [])
  end

  defp api_post(path, token, body) do
    api_json(:post, path, token, body)
  end

  defp api_patch(path, token, body) do
    api_json(:patch, path, token, body)
  end

  defp api_json(method, path, token, body) do
    request =
      [method: method, url: "#{@github_api}#{path}", headers: api_headers(token), json: body] ++
        req_options()

    case Req.request(request) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, format_api_error(status, body)}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp api_headers(token) do
    [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/vnd.github+json"},
      {"user-agent", "cleat-deploy-panel"}
    ]
  end

  defp format_api_error(status, body) when is_map(body) do
    message = body["message"] || inspect(body)
    "GitHub API #{status}: #{message}"
  end

  defp format_api_error(status, body), do: "GitHub API #{status}: #{inspect(body)}"
end
