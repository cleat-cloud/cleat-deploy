# Global deployments index

Authenticated LiveView at `/deployments` listing every deployment in the current tenant.

## Route and nav

- `live "/deployments", DeploymentLive.Index, :index` in the authenticated `live_session`
- Sidebar + mobile nav item **Deploys** (`#nav-deployments` / `#nav-deployments-mobile`) between App Details and Saúde
- `active_tab: :deployments`
- Unauthenticated visit redirects like `/apps`

## Data

- `Deployments.page_for_tenant(scope, page, opts)` in `History`
- Tenant-scoped join on `apps`; order `inserted_at desc, id desc`
- Same page size as per-app history (10)
- Same history fields (no `log`)
- Preload `:app` so the table can link
- `opts`: `:query` (app name/slug/host, case-insensitive like catalog) and `:status` (`:all | :queued | :running | :success | :failed`)

## UI

- Table `#deployments-table` / stream `#deployments-list`
- Columns: App, Status, SHA/ref, Trigger, Duration, When
- App name is a LiveView navigate to `/apps/:id/deployments`
- Status badge reused from `PaasComponents.Badges`
- Filters in the URL: `?query=&status=&page=`
- Search box `#deployments-query` (phx-debounce 150) and status chips All/queued/running/success/failed
- Pagination like the apps listing when `total_pages > 1`
- Empty states: no deploys yet vs no filter match
- Poll 15s while any tenant deploy is queued or running

## Out of scope

- Logs, cancel, enqueue on this page
- API `GET /api/v1/deployments`
- Tenant-wide PubSub topic
