-- Pure layout code: no simulator calls. All measurements include every weight,
-- so changing Normal / Medium / Bold never changes wrapping or window geometry.
local M = {}

-- Inside-only handles leave the surrounding cockpit clickable. Signed edges
-- keep the opposite side anchored, including desktops with negative origins.
function M.resize_edges(x,y,left,bottom,width,height)
    if x<left or x>left+width or y<bottom or y>bottom+height then return nil end
    local margin=6
    return x-left<=margin and -1 or left+width-x<=margin and 1 or 0,
        y-bottom<=margin and -1 or bottom+height-y<=margin and 1 or 0
end

function M.resize_factor(d,x,y)
    local ax,ay=d.hx*d.w,d.hy*d.h
    return 1+((x-d.x)*ax+(y-d.y)*ay)/math.max(1,ax*ax+ay*ay)
end

function M.resize_position(d,width,height,left,top,right,bottom)
    local x=d.left+(d.hx<0 and d.w-width or d.hx==0 and (d.w-width)/2 or 0)
    local y=d.bottom+(d.hy<0 and d.h-height or d.hy==0 and (d.h-height)/2 or 0)
    return math.max(left,math.min(right-width,x)),math.max(bottom,math.min(top-height,y))
end

function M.clamp_size(value)
    value = tonumber(value)
    if not value or value ~= value then return 14 end
    return math.floor(math.max(10, math.min(32, value)) + 0.5)
end

function M.characters(text)
    local result = {}
    for c in tostring(text or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        result[#result + 1] = c
    end
    return result
end

function M.wrap(text, limit, measure)
    local chars, rows, current = M.characters(text), {}, ""
    for _, c in ipairs(chars) do
        if c == "\n" then
            rows[#rows + 1], current = current, ""
        else
            if current ~= "" and measure(current .. c) > limit then
                -- Prefer a word boundary for Latin text; CJK and long identifiers
                -- can safely break between UTF-8 characters, never inside one.
                local head, tail = current:match("^(.*)%s+([^%s]*)$")
                if head and head ~= "" then
                    rows[#rows + 1], current = head, tail
                else
                    rows[#rows + 1], current = current, ""
                end
                if current ~= "" and measure(current .. c) > limit then
                    rows[#rows + 1], current = current, ""
                end
            end
            if c ~= " " or current ~= "" then current = current .. c end
        end
    end
    if current ~= "" or #rows == 0 then rows[#rows + 1] = current end
    return rows
end

function M.build(lines, size, available_w, available_h, vertical, metrics, measure)
    size = M.clamp_size(size)
    available_w, available_h = math.max(1, available_w), math.max(1, available_h)
    local function calculate(px)
        local ascent, descent, height = metrics(px)
        local pad = math.max(6, math.ceil(px * 0.45))
        local accent = 5
        local left, top = pad + (vertical and 0 or accent), pad + (vertical and accent or 0)
        local text_limit = math.max(1, available_w - left - pad)
        local rows, widest = {}, 0
        for source, text in ipairs(lines) do
            for _, row in ipairs(M.wrap(text, text_limit, function(s) return measure(s, px) end)) do
                widest = math.max(widest, measure(row, px))
                rows[#rows + 1] = {text = row, source = source}
            end
        end
        local gap = math.max(height, ascent + descent) + math.max(3, math.ceil(px * 0.22))
        return {
            size = px, rows = rows, left = left, top = top, pad = pad,
            ascent = ascent, descent = descent, gap = gap, accent = accent,
            width = math.min(available_w, math.ceil(widest + left + pad)),
            height = math.ceil(top + ascent + descent + math.max(0, #rows - 1) * gap + pad)
        }
    end
    local result = calculate(size)
    -- Fit short windows without changing the saved user preference.
    while result.height > available_h and result.size > 8 do
        result = calculate(result.size - 1)
    end
    if result.height > available_h then
        local capacity = math.max(1, math.floor((available_h - result.top - result.pad
            - result.ascent - result.descent) / result.gap) + 1)
        while #result.rows > capacity do table.remove(result.rows) end
        local last = result.rows[#result.rows]
        if last then last.text = "..." end
        result.height = available_h
        result.truncated = true
    end
    return result
end

return M
