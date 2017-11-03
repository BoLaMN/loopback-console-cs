'use strict'

path = require 'path'
repl = require './repl'

DEFAULT_REPL_CONFIG =
  quiet: false
  prompt: 'loopback > '
  useGlobal: true
  ignoreUndefined: true
  historyFile: path.join process.env.HOME, '.repl_history' if process.env.HOME
  historyMaxInputSize: 10240

DEFAULT_HANDLE_INFO =
  app: 'The Loopback app handle'
  cb: 'A simplistic results callback that stores and prints'
  result: 'The handle on which cb() stores results'

module.exports =

  activated: ->
    process.env.LOOPBACK_CONSOLE == 'true' or
    process.env.LOOPBACK_CONSOLE == 1 or
    process.argv?.includes '--console'

  start: (app, config) ->
    if @_started
      return Promise.resolve @_ctx

    @_started = true

    config = Object.assign {}, DEFAULT_REPL_CONFIG, config

    ctx = @_ctx =
      app: app
      config: config
      handles: config.handles or {}
      handleInfo: config.handleInfo or {}
      models: {}

    Object.keys(app.models).forEach (modelName) ->
      if not ctx.handles[modelName]
        ctx.models[modelName] = ctx.handles[modelName] = app.models[modelName]

    ctx.handles.app ?= app
    ctx.handles.cb  ?= true

    ctx.handleInfo.app    ?= DEFAULT_HANDLE_INFO.app
    ctx.handleInfo.cb     ?= DEFAULT_HANDLE_INFO.cb
    ctx.handleInfo.result ?= DEFAULT_HANDLE_INFO.result

    replServer = repl ctx
      .on 'SIGINT', -> sawSIGINT = true
      .on 'exit', ->
        if replServer._flushing
          replServer.pause()

          replServer.once 'flushHistory', ->
            process.exit()
        else
          process.exit()
