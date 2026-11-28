// JSON API client. Paths are relative to <base href>, so the site works at /roadvis/ and locally at /.
// Every state-changing request carries the CSRF header the server requires for cookie-authenticated calls.

export class ApiError extends Error {
  constructor(status, detail) {
    super(detail || `HTTP ${status}`);
    this.status = status;
  }
}

export async function api(path, { method = "GET", body, signal } = {}) {
  const headers = { Accept: "application/json" };
  if (method !== "GET") headers["X-RoadVis"] = "1";
  if (body !== undefined) headers["Content-Type"] = "application/json";
  const res = await fetch(path.replace(/^\//, ""), {
    method, headers, signal, credentials: "same-origin", cache: "no-store",
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (res.status === 204) return null;
  let data = null;
  const text = await res.text();
  if (text) {
    try { data = JSON.parse(text); } catch (e) { data = { detail: text }; }
  }
  if (!res.ok) throw new ApiError(res.status, data && data.detail);
  return data;
}
