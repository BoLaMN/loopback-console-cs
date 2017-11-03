'use strict'

fs = require 'fs'
path = require 'path'
vm = require 'vm'
coffee = require 'coffee-script'

{ start, REPLServer } = require 'repl'
{ updateSyntaxError } = require 'coffee-script/lib/coffee-script/helpers'

sawSIGINT = false

wrap = (replServer) ->
  defaultEval = replServer.eval

  runInContext = (js, context, filename) ->
    if context is global
      vm.runInThisContext js, filename
    else
      vm.runInContext js, context, filename

  CoffeeScriptEval = (input, context, filename, cb) ->

    input = input
      .replace /\uFF00/g, '\n'
      .replace /^\(([\s\S]*)\n\)$/m, '$1'
      .replace /^\s*try\s*{([\s\S]*)}\s*catch.*$/m, '$1'

    { Block, Assign, Value
      Literal, Call, Code
    } = require 'coffee-script/lib/coffee-script/nodes'

    try
      tokens = coffee.tokens input
      referencedVars = token[1] for token in tokens when token[0] is 'IDENTIFIER'

      ast = coffee.nodes tokens
      ast = new Block [ new Assign (new Value new Literal '__'), ast, '=' ]
      ast = new Code [], ast

      { isAsync } = ast

      ast    = new Block [ new Call ast ]

      js = ast.compile
        bare: true
        locals: Object.keys(context)
        sharedScope: true
        referencedVars

      result = runInContext js, context, filename

      if isAsync
        result.then (resolved) ->
          cb null, resolved unless sawSIGINT

        sawSIGINT = false
      else
        cb null, result

    catch err

      try
        defaultEval.call @, input, context, filename, cb
      catch e

        updateSyntaxError err, input

        cb err

  (code, context, file, cb) ->

    resolvePromises = (promise, resolved) ->
      Object.keys(context).forEach (key) ->
        if context[key] == promise
          context[key] = resolved

      return

    CoffeeScriptEval code, context, file, (err, result) ->
      if not result?.then
        return cb err, result

      success = (resolved) ->
        resolvePromises result, resolved

        replServer.context.result = resolved

        cb null, resolved

      error = (err) ->
        resolvePromises result, err

        console.log '[31m' + '[Promise Rejection]' + '[0m'

        if err and err.message
          console.log '[31m' + err.message + '[0m'

        cb null, err

      result
        .then success
        .catch err

usage = ({ models, handles, handleInfo, customHandleNames, config }, details) ->
  modelHandleNames = Object.keys models

  customHandleNames = Object.keys(handles).filter (k) ->
    not handleInfo[k] and not models[k]

  txt = """============================================
  Loopback Console

  Primary handles available:

  """

  Object.keys(handleInfo).forEach (key) ->
    txt += " - #{ key }: #{ handleInfo[key] }\n"

  if modelHandleNames.length > 0 or customHandleNames.length > 0
    txt += "\nOther handles available:\n"

  if modelHandleNames.length > 0
    txt += " - Models: #{ modelHandleNames.sort().join(', ') }\n"

  if customHandleNames.length > 0
    txt += "  - Custom: #{ customHandleNames.join(', ') }\n"

  if details
    txt += """
      Examples:
       #{ config.prompt } myUser = User.findOne({ where: { username: 'heath' })
       #{ config.prompt } myUser.updateAttribute('fullName', 'Heath Morrison)
       #{ config.prompt } myUser.widgets.add({ ... })
      """

  txt += "============================================\n\n"

  txt

addMultilineHandler = ({rli, inputStream, outputStream, _prompt, prompt }) ->

  origPrompt = _prompt or prompt

  multiline =
    enabled: off
    initialPrompt: origPrompt.replace /^[^> ]*/, (x) -> x.replace /./g, '-'
    prompt: origPrompt.replace /^[^> ]*>?/, (x) -> x.replace /./g, '.'
    buffer: ''

  nodeLineListener = rli.listeners('line')[0]

  rli.removeListener 'line', nodeLineListener

  rli.on 'line', (cmd) ->
    if multiline.enabled
      multiline.buffer += "#{cmd}\n"

      rli.setPrompt multiline.prompt
      rli.prompt true
    else
      rli.setPrompt origPrompt

      nodeLineListener cmd

    return

  inputStream.on 'keypress', (char, key) ->
    return unless key and key.ctrl and not key.meta and not key.shift and key.name is 'v'

    if multiline.enabled
      unless multiline.buffer.match /\n/
        multiline.enabled = not multiline.enabled

        rli.setPrompt origPrompt
        rli.prompt true

        return

      return if rli.line? and not rli.line.match /^\s*$/

      multiline.enabled = not multiline.enabled

      rli.line = ''
      rli.cursor = 0
      rli.output.cursorTo 0
      rli.output.clearLine 1

      multiline.buffer = multiline.buffer.replace /\n/g, '\uFF00'
      rli.emit 'line', multiline.buffer
      multiline.buffer = ''
    else
      multiline.enabled = not multiline.enabled

      rli.setPrompt multiline.initialPrompt
      rli.prompt true

    return

addModels = (replServer, { models }) ->

  replServer.defineCommand 'models',
    help: 'Display available Loopback models'

    action: ->
      @outputStream.write Object.keys(models).join(', ') + '\n'
      @displayPrompt()

addUsage = (replServer, ctx) ->

  replServer.defineCommand 'usage',
    help: 'Detailed Loopback Console usage information'

    action: ->
      @outputStream.write usage(ctx, true)
      @displayPrompt()

addHistory = (replServer, filename, maxSize) ->
  lastLine = null

  try
    stat = fs.statSync filename
    size = Math.min maxSize, stat.size

    readFd = fs.openSync filename, 'r'

    buffer = new Buffer(size)

    fs.readSync readFd, buffer, 0, size, stat.size - size
    fs.closeSync readFd

    replServer.rli.history = buffer.toString().split('\n').reverse()
    replServer.rli.history.pop() if stat.size > maxSize
    replServer.rli.history.shift() if replServer.rli.history[0] is ''
    replServer.rli.historyIndex = -1

    lastLine = replServer.rli.history[0]

  fd = fs.openSync filename, 'a'

  replServer.rli.addListener 'line', (code) ->
    if code and code.length and code isnt '.history' and code isnt '.exit' and lastLine isnt code
      fs.writeSync fd, "#{code}\n"

      lastLine = code

  replServer.on 'exit', ->
    fs.closeSync fd

  replServer.defineCommand 'history',
    help: 'Show command history'
    action: ->
      @outputStream.write "#{ replServer.rli.history[..].reverse().join '\n' }\n"
      @displayPrompt()

addLoad = (replServer) ->

  replServer.commands.load.help = 'Load CoffeeScript/JavaScript from a file into this REPL session'

module.exports = (ctx) ->
  { quiet, config, handles } = ctx

  if not quiet
    console.log usage ctx

  config = Object.assign {}, config

  replServer = start config

  context = replServer.context

  context.exit = ->
    process.exit 0

  replServer.on 'exit', ->
    replServer.outputStream.write '\n' if not replServer.rli.closed

  addMultilineHandler replServer
  addHistory replServer, config.historyFile, config.historyMaxInputSize
  addUsage replServer, ctx
  addModels replServer, ctx
  addLoad replServer

  Object.assign context, handles

  replServer.eval = wrap replServer

  if handles.cb
    context.result = undefined

    context.cb = (err, result) ->
      context.err = err
      context.result = result

      if err
        console.error 'Error: ' + err

      if not config.quiet
        console.log result

  replServer
