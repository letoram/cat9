return
function(cat9)

local Parser = {}
Parser.transition = {}

function Parser.transition.done(self)
	local rest = self.input:sub(self.i)
	self:reset()
	self.input = rest
	return Parser.transition.header_field
end

function Parser.transition.error(self)
	return Parser.transition.error
end

function Parser.transition.header_field(self)
	local i = self.i

	local crlf = self.input:find("\r\n", i)
	if i == crlf then
		self.i = i + 2
		return Parser.transition.content
	end

	local column = self.input:find(": ", i)
	if not column then
		if crlf then
			self.error = 'Expected ": ", found end of line'
			self.i = crlf
			return Parser.transition.error
		else
			return nil, true
		end
	end

	local key = self.input:sub(i, column-1)
	if #key == 0 then
		self.error = "Empty header key"
		return Parser.transition.error
	end

	local value = self.input:sub(column+2, crlf-1)
	self.headers[key] = value
	self.i = crlf + 2

	return Parser.transition.header_field
end

function Parser.transition.content(self)
	local len = tonumber(self.headers["Content-Length"])
	if not len then
		self.error = "Missing or invalid Content-Length header"
		return Parser.transition.error
	end

	local i = self.i
	if #self.input - i + 1 < len then
		return nil, true
	end

	local msg = self.input:sub(i, i+len-1)
	local ok, err = pcall(function()
		local t, _ = cat9.json.decode(msg)
		self.protomsg = t
	end)

	if not ok then
		self.error = err
		return Parser.transition.error
	end

	self.i = i + len
	return Parser.transition.done
end

function Parser:reset()
	self.next_state = Parser.transition.header_field
	self.input = ""
	self.i = 1
	self.headers = {}

	self.error = nil
	self.protomsg = nil
end

function Parser:feed(msg)
	self.input = self.input .. msg
end

function Parser:next()

	return function()
		if self.next_state == Parser.transition.done then
			self.next_state = self:next_state()
		end

		while self.next_state ~= Parser.transition.done do
			local next, yield = self:next_state()

			if next == Parser.transition.error then
				return false
			end

			if yield then
			-- not enough input, yield
			-- free already consumed stream
				self.input = self.input:sub(self.i)
				self.i = 1
				return nil
			end
			self.next_state = next
		end

		return self.protomsg, self.headers
	end
end

	local parser = setmetatable({}, { __index = Parser })
	parser:reset()
	return parser
end
