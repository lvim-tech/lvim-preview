-- lvim-preview.server.mime: a small extension → Content-Type map. Deliberately minimal —
-- only the types a preview page actually pulls (the shell's own html/css/js, images a
-- markdown/html doc references, the vendored fonts/wasm). Anything unknown is served as
-- application/octet-stream, never guessed, so the browser downloads rather than mis-renders.
--
---@module "lvim-preview.server.mime"

local M = {}

-- Lowercase extension → MIME type.
---@type table<string, string>
M.map = {
    html = "text/html; charset=utf-8",
    htm = "text/html; charset=utf-8",
    css = "text/css; charset=utf-8",
    js = "text/javascript; charset=utf-8",
    mjs = "text/javascript; charset=utf-8",
    json = "application/json; charset=utf-8",
    map = "application/json; charset=utf-8",
    txt = "text/plain; charset=utf-8",
    md = "text/plain; charset=utf-8",
    adoc = "text/plain; charset=utf-8",
    org = "text/plain; charset=utf-8",
    xml = "application/xml; charset=utf-8",
    svg = "image/svg+xml",
    png = "image/png",
    jpg = "image/jpeg",
    jpeg = "image/jpeg",
    gif = "image/gif",
    webp = "image/webp",
    avif = "image/avif",
    ico = "image/x-icon",
    bmp = "image/bmp",
    woff = "font/woff",
    woff2 = "font/woff2",
    ttf = "font/ttf",
    otf = "font/otf",
    eot = "application/vnd.ms-fontobject",
    wasm = "application/wasm",
    pdf = "application/pdf",
    mp4 = "video/mp4",
    webm = "video/webm",
    mp3 = "audio/mpeg",
    ogg = "audio/ogg",
    wav = "audio/wav",
}

--- Content-Type for a path, from its extension. Unknown → octet-stream.
---@param path string
---@return string
function M.for_path(path)
    local ext = path:match("%.([%w]+)$")
    return (ext and M.map[ext:lower()]) or "application/octet-stream"
end

return M
