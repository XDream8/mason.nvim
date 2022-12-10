local registry = require "mason-registry"
local a = require "mason-core.async"
local _ = require "mason-core.functional"
local installer = require "mason-core.installer"
local InstallationHandle = require "mason-core.installer.handle"
local Optional = require "mason-core.optional"
local log = require "mason-core.log"
local EventEmitter = require "mason-core.EventEmitter"
local receipt = require "mason-core.receipt"
local fs = require "mason-core.fs"
local path = require "mason-core.path"
local linker = require "mason-core.installer.linker"
local Result = require "mason-core.result"
local Purl = require "mason-core.purl"

local version_checks = require "mason-core.package.version-check"

---@class Package : EventEmitter
---@field name string
---@field spec RegistryPackageSpec | PackageSpec
---@field private handle InstallHandle The currently associated handle.
local Package = setmetatable({}, { __index = EventEmitter })

---@param package_identifier string
---@return string, string?
Package.Parse = function(package_identifier)
    local name, version = unpack(vim.split(package_identifier, "@"))
    return name, version
end

---@alias PackageLanguage string

---@type table<PackageLanguage, PackageLanguage>
Package.Lang = setmetatable({}, {
    __index = function(s, lang)
        s[lang] = lang
        return s[lang]
    end,
})

---@enum PackageCategory
Package.Cat = {
    Compiler = "Compiler",
    Runtime = "Runtime",
    DAP = "DAP",
    LSP = "LSP",
    Linter = "Linter",
    Formatter = "Formatter",
}

local PackageMt = { __index = Package }

---@class PackageSpec
---@field name string
---@field desc string
---@field homepage string
---@field categories PackageCategory[]
---@field languages PackageLanguage[]
---@field install async fun(ctx: InstallContext)

---@class RegistryPackageSource
---@field id string PURL-compliant identifier.

---@class RegistryPackageSpec
---@field schema '"registry+v1"'
---@field name string
---@field description string
---@field homepage string
---@field licenses string[]
---@field languages string[]
---@field categories string[]
---@field source RegistryPackageSource
---@field bin table<string, string>

---@param spec PackageSpec | RegistryPackageSpec
function Package.new(spec)
    if spec.schema == "registry+v1" then
        vim.validate {
            name = { spec.name, "s" },
            description = { spec.description, "s" },
            homepage = { spec.homepage, "s" },
            licenses = { spec.licenses, "t" },
            categories = { spec.categories, "t" },
            languages = { spec.languages, "t" },
            source = { spec.source, "t" },
            bin = { spec.bin, { "t", "nil" } },
        }
        -- For compatibility with the old PackageSpec structure.
        spec.desc = spec.description
    else
        vim.validate {
            name = { spec.name, "s" },
            desc = { spec.desc, "s" },
            homepage = { spec.homepage, "s" },
            categories = { spec.categories, "t" },
            languages = { spec.languages, "t" },
            install = { spec.install, "f" },
        }
    end

    return EventEmitter.init(setmetatable({
        name = spec.name, -- for convenient access
        spec = spec,
    }, PackageMt))
end

function Package:new_handle()
    self:get_handle():if_present(function(handle)
        assert(handle:is_closed(), "Cannot create new handle because existing handle is not closed.")
    end)
    log.fmt_trace("Creating new handle for %s", self)
    local handle = InstallationHandle.new(self)
    self.handle = handle

    -- Ideally we'd decouple this and leverage Mason's event system, but to allow loading as little as possible during
    -- setup (i.e. not load modules related to Mason's event system) of the mason.nvim plugin we explicitly call into
    -- terminator here.
    require("mason-core.terminator").register(handle)

    self:emit("handle", handle)
    registry:emit("package:handle", self, handle)

    return handle
end

---@alias PackageInstallOpts { version: string?, debug: boolean?, target: string? }

---@param opts? PackageInstallOpts
---@return InstallHandle
function Package:install(opts)
    opts = opts or {}
    return self:get_handle()
        :map(function(handle)
            if not handle:is_closed() then
                log.fmt_debug("Handle %s already exist for package %s", handle, self)
                return handle
            end
        end)
        :or_else_get(function()
            local handle = self:new_handle()
            a.run(
                installer.execute,
                ---@param success boolean
                ---@param result Result
                function(success, result)
                    if not success then
                        -- Installer failed abnormally (i.e. unexpected exception in the installer code itself).
                        log.error("Unexpected error", result)
                        self:emit("install:failed", handle)
                        registry:emit("package:install:failed", self, handle)

                        -- We terminate _after_ emitting failure events because termination -> failed is handled
                        -- differently than failed -> terminate in the :Mason UI window (termination -> failed is
                        -- interpreted as a user-triggered termination and is interpreted differently).
                        if not handle:is_closed() and not handle.is_terminated then
                            handle.stdio.sink.stderr(tostring(result))
                            handle.stdio.sink.stderr "\nInstallation failed abnormally. Please report this error."
                            handle:terminate()
                        end
                        return
                    end
                    result
                        :on_success(function()
                            self:emit("install:success", handle)
                            registry:emit("package:install:success", self, handle)
                        end)
                        :on_failure(function()
                            self:emit("install:failed", handle)
                            registry:emit("package:install:failed", self, handle)
                        end)
                end,
                handle,
                opts
            )
            return handle
        end)
end

function Package:uninstall()
    local was_unlinked = self:unlink()
    if was_unlinked then
        self:emit "uninstall:success"
        registry:emit("package:uninstall:success", self)
    end
    return was_unlinked
end

function Package:unlink()
    log.fmt_trace("Unlinking %s", self)
    local install_path = self:get_install_path()
    -- 1. Unlink
    self:get_receipt():map(_.prop "links"):if_present(function(links)
        linker.unlink(self, links)
    end)

    -- 2. Remove installation artifacts
    if fs.sync.dir_exists(install_path) then
        fs.sync.rmrf(install_path)
        return true
    end
    return false
end

function Package:is_installed()
    return registry.is_installed(self.name)
end

function Package:get_handle()
    return Optional.of_nilable(self.handle)
end

function Package:get_install_path()
    return path.package_prefix(self.name)
end

---@return Optional # Optional<InstallReceipt>
function Package:get_receipt()
    local receipt_path = path.concat { self:get_install_path(), "mason-receipt.json" }
    if fs.sync.file_exists(receipt_path) then
        return Optional.of(receipt.InstallReceipt.from_json(vim.json.decode(fs.sync.read_file(receipt_path))))
    end
    return Optional.empty()
end

---@param callback fun(success: boolean, version_or_err: string)
function Package:get_installed_version(callback)
    if self.spec.schema == "registry+v1" then
        local resolve = _.curryN(callback, 2)
        self:get_receipt()
            :ok_or("Unable to get receipt.")
            :map(_.path { "primary_source", "id" })
            :and_then(function(id)
                return Purl.parse(id):map(_.prop "version")
            end)
            :on_success(resolve(true))
            :on_failure(resolve(false))
    else
        a.run(function()
            local receipt = self:get_receipt():or_else_throw "Unable to get receipt."
            return version_checks.get_installed_version(receipt, self:get_install_path()):get_or_throw()
        end, callback)
    end
end

---@param callback fun(success: boolean, result_or_err: NewPackageVersion)
function Package:check_new_version(callback)
    if self.spec.schema == "registry+v1" then
        self:get_installed_version(function(success, installed_version)
            if not success then
                return callback(false, installed_version)
            end
            local resolve = _.curryN(callback, 2)
            Purl.parse(self.spec.source.id)
                :and_then(
                    ---@param purl Purl
                    function(purl)
                        if purl.version and installed_version ~= purl.version then
                            return Result.success {
                                name = purl.name,
                                current_version = installed_version,
                                latest_version = purl.version,
                            }
                        else
                            return Result.failure "Package is not outdated."
                        end
                    end
                )
                :on_success(resolve(true))
                :on_failure(resolve(false))
        end)
    else
        a.run(function()
            local receipt = self:get_receipt():or_else_throw "Unable to get receipt."
            return version_checks.get_new_version(receipt, self:get_install_path()):get_or_throw()
        end, callback)
    end
end

function Package:get_lsp_settings_schema()
    local ok, schema = pcall(require, ("mason-schemas.lsp.%s"):format(self.name))
    if not ok then
        return Optional.empty()
    end
    return Optional.of(schema)
end

function PackageMt.__tostring(self)
    return ("Package(name=%s)"):format(self.name)
end

return Package
