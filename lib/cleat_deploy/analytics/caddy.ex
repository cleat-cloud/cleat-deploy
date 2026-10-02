defmodule CleatDeploy.Analytics.Caddy do
  @moduledoc """
  Caddyfile site blocks for analytics inject, failover, and static loopback.
  """

  alias CleatDeploy.Analytics

  @spec public_site(map(), keyword()) :: String.t()
  def public_site(app, opts \\ []) do
    inject? = field(app, :analytics_inject) == true
    runtime = field(app, :runtime)

    cond do
      inject? -> inject_on_site(app, opts)
      runtime == "static" -> static_off_site(app, opts)
      true -> runtime_off_site(app, opts)
    end
  end

  @spec loopback_site(map(), keyword()) :: String.t() | nil
  def loopback_site(app, opts \\ []) do
    if field(app, :runtime) == "static" and field(app, :analytics_inject) == true do
      port = field(app, :port)
      static_root = Keyword.fetch!(opts, :static_root)
      robots_header = Keyword.get(opts, :robots_header, "")

      """
      http://127.0.0.1:#{port} {
        bind 127.0.0.1
        root * #{static_root}
        try_files {path} {path}/index.html /index.html
        header Cache-Control "no-cache"
        #{robots_header}
        file_server
      }
      """
    end
  end

  @spec address(String.t()) :: String.t()
  def address(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _ip} -> "http://#{host}"
      _ -> host
    end
  end

  defp inject_on_site(app, opts) do
    host = address(field(app, :host))
    slug = field(app, :slug)
    port = field(app, :port)
    listen = Analytics.listen_port()

    # Caddy 2.11 sorts site-level forward_auth before handle, so collect
    # paths stay exclusive only if wake+WS+failover live in a fallback handle.
    [
      """
      #{host} {
        # paas:app=#{slug}
        log
        encode gzip
        handle /cleat/a.js {
          reverse_proxy 127.0.0.1:#{listen}
        }
        handle /cleat/a {
          reverse_proxy 127.0.0.1:#{listen}
        }
        handle {
      """,
      wake_block(app, opts, "    "),
      """
          @cleat_ws {
            header Connection *Upgrade*
            header Upgrade websocket
          }
          handle @cleat_ws {
            reverse_proxy 127.0.0.1:#{port}
          }
          reverse_proxy 127.0.0.1:#{listen} 127.0.0.1:#{port} {
            lb_policy first
            lb_retries 1
            fail_duration 10s
            max_fails 1
            transport http {
              dial_timeout 250ms
            }
          }
        }
      }
      """
    ]
    |> IO.iodata_to_binary()
  end

  defp wake_block(app, opts, pad) do
    case Keyword.get(opts, :wake_unit) do
      unit when is_binary(unit) ->
        """
        #{pad}forward_auth 127.0.0.1:#{opts[:wake_port] || 3900} {
        #{pad}  uri /wake?unit=#{unit}&port=#{field(app, :port)}
        #{pad}}
        """

      _ ->
        ""
    end
  end

  defp runtime_off_site(app, opts) do
    host = address(field(app, :host))
    slug = field(app, :slug)
    port = field(app, :port)

    [
      """
      #{host} {
        # paas:app=#{slug}
        log
        encode gzip
      """,
      wake_block(app, opts, "  "),
      """
        reverse_proxy 127.0.0.1:#{port}
      }
      """
    ]
    |> IO.iodata_to_binary()
  end

  defp static_off_site(app, opts) do
    host = address(field(app, :host))
    slug = field(app, :slug)
    static_root = Keyword.fetch!(opts, :static_root)
    robots_header = Keyword.get(opts, :robots_header, "")

    """
    #{host} {
      # paas:app=#{slug}
      log
      encode gzip
      root * #{static_root}
      try_files {path} {path}/index.html /index.html
      header Cache-Control "no-cache"
      #{robots_header}
      file_server
    }
    """
  end

  defp field(app, key) do
    Map.get(app, key, Map.get(app, Atom.to_string(key)))
  end
end
