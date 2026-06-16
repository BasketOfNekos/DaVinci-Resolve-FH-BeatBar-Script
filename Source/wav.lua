-- wav.lua
local wav = {}


local function read_u32_le(s)
  local a,b,c,d = string.byte(s,1,4)
  return a + b*256 + c*65536 + d*16777216
end


local function read_u16_le(s)
  local a,b = string.byte(s,1,2)
  return a + b*256
end


-- function to read one aframe (returns table of channel samples as signed ints)
local function read_aframe(f, aframe_bytes, num_channels, bits_per_sample)
    local bytes = f:read(aframe_bytes)
    if not bytes or #bytes < aframe_bytes then return nil end
    local samples = {}
    local idx = 1
    for channel =1,num_channels do
        if bits_per_sample == 8 then
            local v = string.byte(bytes, idx)
            -- 8-bit WAV is unsigned 0..255, center 128
            v = v - 128
            samples[channel] = v * 256 -- scale to roughly 16-bit range for thresholding convenience
            idx = idx + 1
        else -- 16-bit LE
            local lo = string.byte(bytes, idx)
            local hi = string.byte(bytes, idx+1)
            local val = lo + hi*256
            if val >= 32768 then val = val - 65536 end
            samples[channel] = val
            idx = idx + 2
        end
    end
    return samples
end


-- helper to compute sample magnitude (for stereo use max channel)
local function mag(aframe)
    local magnitude = 0
    for channel=1,#aframe do
        local absoluteValue = math.abs(aframe[channel])
        if absoluteValue > magnitude then magnitude = absoluteValue end
    end
    return magnitude
end


function wav.process(fname, min_sep_vframe, vframe_rate)
    local threshold = 8000 --20000 -- for 16-bit PCM default (max is +/-32767)

    local f = io.open(fname, "rb")
    if not f then error("Cannot open file: "..fname) end

    -- Read RIFF header
    local riff = f:read(12)
    if not riff or #riff < 12 then error("Not a valid RIFF file") end
    if riff:sub(1,4) ~= "RIFF" then error("Not a RIFF file") end
    -- file size = read_u32_le(riff:sub(5,8)) -- skip
    if riff:sub(9,12) ~= "WAVE" then error("Not a WAVE file") end

    -- find fmt and data chunks
    local fmt_chunk_found, data_chunk_found
    local audio_format, num_channels, sample_rate, byte_rate, block_align, bits_per_sample
    local data_pos, data_size
    while true do
        local hdr = f:read(8)
        if not hdr or #hdr < 8 then break end
        local chunk_id = hdr:sub(1,4)
        local chunk_size = read_u32_le(hdr:sub(5,8))
        if chunk_id == "fmt " then
            local body = f:read(chunk_size)
            audio_format = read_u16_le(body:sub(1,2))
            num_channels = read_u16_le(body:sub(3,4))
            sample_rate = read_u32_le(body:sub(5,8))
            byte_rate = read_u32_le(body:sub(9,12))
            block_align = read_u16_le(body:sub(13,14))
            bits_per_sample = read_u16_le(body:sub(15,16))
            fmt_chunk_found = true
        elseif chunk_id == "data" then
            data_pos = f:seek("cur")  -- position AFTER reading header, but before reading data
            data_size = chunk_size
            data_chunk_found = true
            break
        else
            local toskip = chunk_size
            if toskip % 2 == 1 then toskip = toskip + 1 end
            f:seek("cur", toskip) -- skip unknown chunk (pad if odd)
        end
    end
    if not fmt_chunk_found or not data_chunk_found then error("Missing fmt or data chunk") end
    if audio_format ~= 1 then error("Only PCM format supported (audio_format="..tostring(audio_format)..")") end
    if not (bits_per_sample == 8 or bits_per_sample == 16) then error("Only 8-bit or 16-bit supported") end

    f:seek("set", data_pos) -- data_pos currently points at file position right after chunk header; move back to body start
    local bytes_per_sample = bits_per_sample/8
    local aframe_bytes = bytes_per_sample * num_channels
    local total_aframes = math.floor(data_size / aframe_bytes)

    local hits = {}
    for i=1,total_aframes do
        local aframe = read_aframe(f, aframe_bytes, num_channels, bits_per_sample)
        if not aframe then break end

        if mag(aframe) >= threshold then
            local time = (i-1) / sample_rate -- zero-based index -> seconds
            -- TODO work on the math here necessary for making this spit out aframe with a given FPS, maybe dont skip anything here but just de-dupe later with the aframes.

            time = vframe_rate * time -- Convert to frames per second using the provided fps of a video.

            -- Enforce minimum separation
            if min_sep_vframe > 0 and #hits > 0 then
                if time - hits[#hits] >= min_sep_vframe then
                    hits[#hits+1] = time
                end
            else
                hits[#hits+1] = time
            end
        end
    end
    f:close()

    print(string.format("Found %d pulses", #hits))
    return hits
end

return wav
