require('spec.helpers')

local migration = require('diffs.migration')

local message = table.concat({
  '[diffs.nvim] This repository will be removed from GitHub on October 31, 2026.',
  'Install from Forgejo: https://forge.barrettruth.com/barrettruth/diffs.nvim.',
  'See :help diffs-migration.',
}, ' ')

local github_origin = 'https://github.com/barrettruth/diffs.nvim.git'

describe('diffs.migration', function()
  it('matches the supported GitHub origins', function()
    for _, origin in ipairs({
      'https://github.com/barrettruth/diffs.nvim',
      'http://github.com/barrettruth/diffs.nvim',
      'git://github.com/barrettruth/diffs.nvim',
      'ssh://git@github.com/barrettruth/diffs.nvim',
      'git@github.com:barrettruth/diffs.nvim',
    }) do
      for _, suffix in ipairs({ '', '.git', '/', '.git///' }) do
        assert.is_true(migration.is_github_origin(origin .. suffix))
      end
    end
  end)

  it('rejects other origins and non-string values', function()
    for _, origin in ipairs({
      'https://forge.barrettruth.com/barrettruth/diffs.nvim.git',
      'https://github.com/other/diffs.nvim',
      'https://github.com/barrettruth/other.nvim',
      'https://github.com/barrettruth/diffs.nvim.extra',
      'https://github.com.example/barrettruth/diffs.nvim',
      '',
      false,
      {},
    }) do
      assert.is_false(migration.is_github_origin(origin))
    end
    assert.is_false(migration.is_github_origin(nil))
  end)

  describe('asynchronous origin check', function()
    local original = {}
    local jobs
    local notifications

    before_each(function()
      jobs = {}
      notifications = {}
      original.jobstart = vim.fn.jobstart
      original.executable = vim.fn.executable
      original.system = vim.fn.system
      original.jobwait = vim.fn.jobwait
      original.notify_once = vim.notify_once
      vim.fn.executable = function(name)
        assert.are.equal('git', name)
        return 1
      end
      vim.fn.system = function()
        error('Synchronous execution is not permitted')
      end
      vim.fn.jobwait = function()
        error('Waiting for the job is not permitted')
      end
      vim.fn.jobstart = function(command, opts)
        jobs[#jobs + 1] = { command = command, opts = opts }
        return #jobs
      end
      vim.notify_once = function(text, level)
        assert.is_false(vim.in_fast_event())
        notifications[#notifications + 1] = { text, level }
      end
    end)

    after_each(function()
      vim.fn.jobstart = original.jobstart
      vim.fn.executable = original.executable
      vim.fn.system = original.system
      vim.fn.jobwait = original.jobwait
      vim.notify_once = original.notify_once
    end)

    local function drain()
      local done = false
      vim.schedule(function()
        done = true
      end)
      assert.is_true(vim.wait(1000, function()
        return done
      end))
    end

    local function complete(origin, code)
      jobs[1].opts.on_stdout(1, { origin, '' })
      jobs[1].opts.on_exit(1, code)
    end

    it('starts a buffered job and returns before completion', function()
      migration.warn_if_github_source('/tmp/plugin with spaces')
      assert.same({
        'git',
        '-C',
        '/tmp/plugin with spaces',
        'config',
        '--get',
        'remote.origin.url',
      }, jobs[1].command)
      assert.is_true(jobs[1].opts.stdout_buffered)
      assert.same({}, notifications)
      complete('  ' .. github_origin .. '\r', 0)
      assert.same({}, notifications)
      drain()
      assert.same({ { message, vim.log.levels.WARN } }, notifications)
    end)

    it('schedules notification outside a fast callback', function()
      migration.warn_if_github_source()
      assert.are.equal(migration.plugin_root(), jobs[1].command[3])
      local timer = assert(vim.uv.new_timer())
      local fast_event
      timer:start(0, 0, function()
        fast_event = vim.in_fast_event()
        complete(github_origin, 0)
        timer:close()
      end)
      assert.is_true(vim.wait(1000, function()
        return #notifications == 1
      end))
      assert.is_true(fast_event)
      assert.same({ { message, vim.log.levels.WARN } }, notifications)
    end)

    it('ignores unsuccessful Git commands', function()
      migration.warn_if_github_source()
      complete(github_origin, 1)
      drain()
      assert.same({}, notifications)
    end)

    it('ignores non-GitHub origins', function()
      migration.warn_if_github_source()
      complete('https://forge.barrettruth.com/barrettruth/diffs.nvim.git', 0)
      drain()
      assert.same({}, notifications)
    end)

    it('ignores empty output', function()
      migration.warn_if_github_source()
      complete('', 0)
      drain()
      assert.same({}, notifications)
    end)

    it('does not start a job without Git', function()
      vim.fn.executable = function()
        return 0
      end
      migration.warn_if_github_source()
      assert.same({}, jobs)
      assert.same({}, notifications)
    end)

    it('ignores job start failures', function()
      for _, result in ipairs({ 0, -1 }) do
        vim.fn.jobstart = function()
          return result
        end
        assert.has_no.errors(migration.warn_if_github_source)
      end
      vim.fn.jobstart = function()
        error('Cannot start Git')
      end
      assert.has_no.errors(migration.warn_if_github_source)
      assert.same({}, notifications)
    end)
  end)

  describe('Git subprocess', function()
    local root
    before_each(function()
      root = vim.fn.tempname()
      vim.fn.mkdir(root, 'p')
      vim.fn.system({ 'git', '-C', root, 'init', '--quiet' })
      assert.are.equal(0, vim.v.shell_error)
    end)

    after_each(function()
      vim.fn.delete(root, 'rf')
    end)

    it('reads and trims the origin through the callback', function()
      vim.fn.system({ 'git', '-C', root, 'config', 'remote.origin.url', github_origin })
      assert.are.equal(0, vim.v.shell_error)
      local origin
      migration.origin(root, function(value)
        assert.is_false(vim.in_fast_event())
        origin = value
      end)
      assert.is_nil(origin)
      assert.is_true(vim.wait(1000, function()
        return origin ~= nil
      end))
      assert.are.equal(github_origin, origin)
    end)
  end)
end)
