#================================
#  SSH2Shel
#================================
# Description
# SSH2 wrapper for creating a SSH shell connection and running multiple commands sequentially.
typeIsArray = Array.isArray || ( value ) -> return {}.toString.call( value ) is '[object Array]'
EventEmitter = require('events').EventEmitter

class SSH2Shell extends EventEmitter
  sshObj:           {}
  command:          ""
  hosts:            []
  _connections:     []
  _stream:          {}
  _data:            ""
  _buffer:          ""
  idleTime:         5000
  asciiFilter:      ""
  textColorFilter:  ""
  passwordPromt:    ""
  passphrasePromt:  ""
  standardPrompt:    ""
  _callback:          =>
  onCommandProcessing:=>
  onCommandComplete:  =>
  onCommandTimeout:   =>
  onEnd:              =>
  pipe:                =>
  unpipe:             =>

  _processData: ( data )=>
    #add host response data to buffer

    @_buffer += data
    if @command.length > 0 and not @standardPrompt.test(@_sanitizeResponse())
      #continue loading the buffer and set/reset a timeout
      @.emit 'commandProcessing' , @command, @_buffer, @sshObj, @_stream
      clearTimeout @sshObj.idleTimer if @sshObj.idleTimer
      @sshObj.idleTimer = setTimeout( =>
          @.emit 'commandTimeout', @.command, @._buffer, @._stream, @._connection
      , @idleTime)
    else if @command.length < 1 and not @standardPrompt.test(@_buffer)
      @.emit 'commandProcessing' , @command, @_buffer, @sshObj, @_stream

    #Set a timer to fire when no more data events are received
    #and then process the buffer based on command and prompt combinations
    clearTimeout @sshObj.dataReceivedTimer if @sshObj.dataReceivedTimer
    @sshObj.dataReceivedTimer = setTimeout( =>
      #clear the command timeout timer
      clearTimeout @sshObj.idleTimer if @sshObj.idleTimer

      #remove test coloring from responses like [32m[31m
      unless @.sshObj.disableColorFilter
        @emit 'msg', "#{@sshObj.server.host}: text formatting filter: "+@sshObj.textColorFilter+", filtered: "+@textColorFilter.test(@_buffer) if @sshObj.verbose
        @_buffer = @_buffer.replace(@textColorFilter, "")

      #remove non-standard ascii from terminal responses
      unless @.sshObj.disableASCIIFilter
        @emit 'msg', "#{@sshObj.server.host}: Non-standard ASCII filtered: "+@asciiFilter.test(@_buffer) if @sshObj.verbose
        @_buffer = @_buffer.replace(@asciiFilter, "")

      switch (true)
        #check if sudo password is needed
        when @command.length > 0 and @command.indexOf("sudo ") isnt -1
          @emit 'msg', "#{@sshObj.server.host}: Sudo command data" if @sshObj.debug
          @_processPasswordPrompt()
        #check if ssh authentication needs to be handled
        when @command.length > 0 and @command.indexOf("ssh ") isnt -1
          @emit 'msg', "#{@sshObj.server.host}: SSH command data" if @sshObj.debug
          @_processSSHPrompt()
        #check for standard prompt from a command
        when @command.length > 0 and @standardPrompt.test(@_sanitizeResponse())
          @emit 'msg', "#{@sshObj.server.host}: Normal prompt detected" if @sshObj.debug
          @sshObj.pwSent = false #reset sudo prompt checkable
          @_commandComplete()
        #check for no command but first prompt detected
        when @command.length < 1 and @standardPrompt.test(@_buffer)
          @emit 'msg', "#{@sshObj.server.host}: First prompt detected" if @sshObj.debug
          @sshObj.sessionText += @_buffer if @sshObj.showBanner
          @_nextCommand()
        else
          @emit 'msg', "Data processing: data received timeout" if @sshObj.debug
          @sshObj.idleTimer = setTimeout( =>
              @.emit 'commandTimeout', @.command, @._buffer, @._stream, @._connection
          , @idleTime)
    , 500)

  _sanitizeResponse: =>
    return @_buffer.replace(@command.substr(0, @_buffer.length), "")

  _processPasswordPrompt: =>
    #First test for password prompt
    response = @_sanitizeResponse().trim()
    passwordPrompt =  @passwordPromt.test(response)
    passphrase =  @passphrasePromt.test(response)
    standardPrompt = @standardPrompt.test(response)
    @.emit 'msg', "#{@sshObj.server.host}: Password sent: #{@sshObj.pwSent}" if @sshObj.verbose 
    @.emit 'msg', "#{@sshObj.server.host}: Password prompt: Password previously sent: #{@sshObj.pwSent}" if @sshObj.debug
    @.emit 'msg', "#{@sshObj.server.host}: Response: #{response}" if @sshObj.verbose
    @.emit 'msg', "#{@sshObj.server.host}: Sudo Password Prompt: #{passwordPrompt}" if @sshObj.verbose
    @.emit 'msg', "#{@sshObj.server.host}: Sudo Password: #{@sshObj.server.password}" if @sshObj.verbose
    #normal prompt so continue with next command
    if standardPrompt
      @.emit 'msg', "#{@sshObj.server.host}: Password prompt: Standard prompt detected" if @sshObj.debug
      @_commandComplete()
      @sshObj.pwSent = true
    #Password prompt detection
    else unless @sshObj.pwSent
      if passwordPrompt
        @.emit 'msg', "#{@sshObj.server.host}: Password prompt: Buffer: #{response}" if @sshObj.verbose
        @.emit 'msg', "#{@sshObj.server.host}: Password prompt: Send password " if @sshObj.debug
        @.emit 'msg', "#{@sshObj.server.host}: Sent password: #{@sshObj.server.password}" if @sshObj.verbose
        #send password
        @sshObj.pwSent = true
        @_runCommand("#{@sshObj.server.password}")
      else
        @.emit 'msg', "#{@sshObj.server.host}: Password prompt: not detected first test" if @sshObj.debug

    #password sent so either check for failure or run next command
    else if passwordPrompt
        @.emit 'msg', "#{@sshObj.server.host}: Sudo password faied: response: #{response}" if @sshObj.verbose
        @.emit 'error', "#{@sshObj.server.host}: Sudo password was incorrect for #{@sshObj.server.userName}", "Sudo authentication" if @sshObj.debug
        @.emit 'msg', "#{@sshObj.server.host}: Failed password prompt: Password: [#{@sshObj.server.password}]" if @sshObj.debug
        #add buffer to sessionText so the sudo response can be seen
        @sshObj.sessionText += "#{@_buffer}"
        @_buffer = ""
        #@sshObj.commands = []
        @command = ""
        @_stream.write '\x03'
      

  _processSSHPrompt: =>
    #not authenticated yet so detect prompts
    response = @_sanitizeResponse().trim()
    passwordPrompt =  @passwordPromt.test(response) and not @sshObj.server.hasOwnProperty("passPhrase")
    passphrasePrompt =  @passphrasePromt.test(response) and @sshObj.server.hasOwnProperty("passPhrase")
    standardPrompt = @standardPrompt.test(response)
    
    @.emit 'msg', "#{@sshObj.server.host}: Password sent: #{@sshObj.sshAuth},\n\tPrompt regex: #{@passwordPromt}" if @sshObj.verbose
    @.emit 'msg', "#{@sshObj.server.host}: Response: |#{response}|" if @sshObj.verbose
    @.emit 'msg', "#{@sshObj.server.host}: Password prompt: #{passwordPrompt},\n\t
      Passphrase prompt: #{passphrasePrompt},\n\tStandard prompt: #{standardPrompt}" if @sshObj.verbose
    unless @sshObj.sshAuth
      @.emit 'msg', "#{@sshObj.server.host}: First SSH prompt detection" if @sshObj.debug
      
      #provide password
      if passwordPrompt
        @.emit 'msg', "#{@sshObj.server.host}: SSH send password" if @sshObj.debug
        @sshObj.sshAuth = true
        @_buffer = ""
        @_runCommand("#{@sshObj.server.password}")
      #provide passphrase
      else if passphrasePrompt
        @.emit 'msg', "#{@sshObj.server.host}: SSH send passphrase" if @sshObj.debug
        @sshObj.sshAuth = true
        @_buffer = ""
        @_runCommand("#{@sshObj.server.passPhrase}")
      #normal prompt so continue with next command
      else if standardPrompt
        @.emit 'msg', "#{@sshObj.server.host}: SSH standard prompt" if @sshObj.debug
        @sshObj.sshAuth = true
        @sshObj.sessionText += "Connected to #{@sshObj.server.host}"
        @sshObj.exitCommands.push "exit" 
        @_nextCommand()
    else
      @.emit 'msg', "#{@sshObj.server.host}: SSH post authentication prompt detection" if @sshObj.debug
      #normal prompt after authentication, start running commands.
      if standardPrompt
        @.emit 'msg', "#{@sshObj.server.host}: SSH complete: normal prompt" if @sshObj.debug
        @sshObj.exitCommands.push "exit" 
        @_nextCommand()
      #Password or passphase detected a second time after authentication indicating failure.
      else if (passwordPrompt or passphrasePrompt)
        @.emit 'msg', "#{@sshObj.server.host}: SSH auth failed" if @sshObj.debug
        @sshObj.sshAuth = false
        using = switch
          when passwordPrompt then "password: |#{@sshObj.server.password}|"
          when passphrasePrompt then "passphrase: |#{@sshObj.server.passPhrase}|"
        @.emit 'error', "#{@sshObj.server.host}: SSH authentication failed for #{@sshObj.server.userName}@#{@sshObj.server.host}", "Nested host authentication"
        @.emit 'msg', "#{@sshObj.server.host}: SSH auth failed: Using " + using if @sshObj.debug
        
        #no connection so drop back to first host settings if there was one
        @sshObj.sessionText += "#{@_buffer}"
        
        if @_connections.length > 0
          return @_previousHost()
          #@sshObj = @_connections.pop()
        #add buffer to sessionText so the ssh response can be seen
        
        #send ctrl-c to exit authentication prompt
        #@_stream.write '\x03'
        @_runExit()

  _processNotifications: =>
    #check for notifications in commands
    if @command
      #this is a message for the sessionText like an echo command in bash
      if (sessionNote = @command.match(/^`(.*)`$/))
        @.emit 'msg', "#{@sshObj.server.host}: Notifications: sessionText output" if @sshObj.debug
        @sshObj.sessionText += "#{@sshObj.server.host}: Note: #{sessionNote[1]}#{@sshObj.enter}"
        @.emit 'msg', sessionNote[1] if @sshObj.verbose
        @_nextCommand()
      #this is a message to output in process
      else if (msgNote = @command.match(/^msg:(.*)$/))
        @.emit 'msg', "#{@sshObj.server.host}: Notifications: msg to output" if @sshObj.debug
        @.emit 'msg', "#{@sshObj.server.host}: Note: #{msgNote[1]}"
        @_nextCommand()
      else
        @.emit 'msg', "#{@sshObj.server.host}: Notifications: Normal Command to run" if @sshObj.debug
        @_checkCommand()

  _commandComplete: =>
    response = @_buffer.replace(@command, "")
    #check sudo su has been authenticated and add an extra exit command
    if @command.indexOf("sudo su") isnt -1
      @.emit 'msg', "#{@sshObj.server.host}: Sudo su adding exit." if @sshObj.debug
      @sshObj.exitCommands.push "exit"

    if @command isnt "" and @command isnt "exit" and @command.indexOf("ssh ") is -1
      @.emit 'msg', "#{@sshObj.server.host}: Command complete:\nCommand:\n #{@command}\nResponse: #{response}" if @sshObj.verbose
      #Not running an exit command or first prompt detection after connection
      #load the full buffer into sessionText and raise a commandComplete event

      @sshObj.sessionText += response
      @.emit 'msg', "#{@sshObj.server.host}: Raising commandComplete event" if @sshObj.debug
      @.emit 'commandComplete', @command, @_buffer, @sshObj

    if @command.indexOf("exit") != -1
      @_runExit()
    else
      @_nextCommand()

  _nextCommand: =>
    @_buffer = ""
    #process the next command if there are any
    if @sshObj.commands.length > 0
      @.emit 'msg', "#{@sshObj.server.host}: Host.commands: #{@sshObj.commands}" if @sshObj.verbose
      @command = @sshObj.commands.shift()
      @.emit 'msg', "#{@sshObj.server.host}: Next command from host.commands: #{@command}" if @sshObj.verbose
      @_processNotifications()
    else
      @.emit 'msg', "#{@sshObj.server.host}: No commands so exit" if @sshObj.debug
      #no more commands so exit
      @_runExit()

  _checkCommand: =>
    #if there is still a command to run then run it or exit
    if @command
      @_runCommand(@command)
    else
      #no more commands so exit
      @.emit 'msg', "#{@sshObj.server.host}: No command so exit" if @sshObj.debug
      @_runExit()

  _runCommand: (command) =>
    @.emit 'msg', "#{@sshObj.server.host}: sending: #{command}" if @sshObj.verbose
    @.emit 'msg', "#{@sshObj.server.host}: run command" if @sshObj.debug
    @_stream.write "#{command}#{@sshObj.enter}"

  _previousHost: =>
    @.emit 'msg', "#{@sshObj.server.host}: Load previous host config" if @sshObj.debug
    host = @sshObj.server.host

    @.emit 'end', "#{@sshObj.server.host}: \n#{@sshObj.sessionText}", @sshObj
    @.emit 'msg', "#{@sshObj.server.host}: Previous hosts: #{@_connections.length}" if @sshObj.debug
    if @_connections.length > 0
      clearTimeout @sshObj.idleTimer if @sshObj.idleTimer
      @.removeListener 'commandProcessing', @onCommandProcessing
      @.removeListener 'commandComplete', @onCommandComplete
      @.removeListener 'commandTimeout',  @onCommandTimeout
      @.removeListener 'end', @onEnd
      @sshObj = @_connections.pop()
      @.emit 'msg', "#{@sshObj.enter}Previous host object:\n#{@sshObj}" if @sshObj.verbose
      @.emit 'msg', "#{@sshObj.server.host}: Reload previous host" if @sshObj.debug
      return @_loadDefaults(@_runExit)

    @_runExit()

  _nextHost: =>
    @_buffer = ""
    nextHost = @sshObj.hosts.shift()
    @.emit 'msg', "#{@sshObj.server.host}: SSH to #{nextHost.server.host}" if @sshObj.debug
    @.emit 'msg', "#{@sshObj.server.host}: Clearing previous event handlers" if @sshObj.debug
    @.removeListener 'commandProcessing', @onCommandProcessing
    @.removeListener 'commandComplete', @onCommandComplete
    @.removeListener 'commandTimeout',  @onCommandTimeout
    @.removeListener 'end', @onEnd        
    @_connections.push(@sshObj)      
    @sshObj = nextHost 
    @_loadDefaults(@_sshConnect)
    

  _sshConnect: =>
    #add ssh commandline options from host.server.ssh
    sshFlags   = "-x"
    sshOptions = ""
    if @sshObj.server.ssh
      sshFlags   += @sshObj.server.ssh.forceProtocolVersion if @sshObj.server.ssh.forceProtocolVersion
      sshFlags   += @sshObj.server.ssh.forceAddressType if @sshObj.server.ssh.forceAddressType
      sshFlags   += "T" if @sshObj.server.ssh.disablePseudoTTY
      sshFlags   += "t" if @sshObj.server.ssh.forcePseudoTTY
      sshFlags   += "v" if @sshObj.server.ssh.verbose

      sshOptions += " -c " + @sshObj.server.ssh.cipherSpec if @sshObj.server.ssh.cipherSpec
      sshOptions += " -e " + @sshObj.server.ssh.escape if @sshObj.server.ssh.escape
      sshOptions += " -E " + @sshObj.server.ssh.logFile if @sshObj.server.ssh.logFile
      sshOptions += " -F " + @sshObj.server.ssh.configFile if @sshObj.server.ssh.configFile
      sshOptions += " -i " + @sshObj.server.ssh.identityFile if @sshObj.server.ssh.identityFile
      sshOptions += " -l " + @sshObj.server.ssh.loginName if @sshObj.server.ssh.loginName
      sshOptions += " -m " + @sshObj.server.ssh.macSpec if @sshObj.server.ssh.macSpec
      sshOptions += ' -o "#{option}={#value}"' for option,value of @sshObj.server.ssh.Options
    sshOptions += ' -o "StrictHostKeyChecking=no"'
    sshOptions += " -p #{@sshObj.server.port}"
    @sshObj.sshAuth = false
    @command = "ssh #{sshFlags} #{sshOptions} #{@sshObj.server.userName}@#{@sshObj.server.host}"
    @.emit 'msg', "#{@sshObj.server.host}: SSH command: connect" if @sshObj.debug
    @_runCommand(@command)

  _runExit: =>
    @.emit 'msg', "#{@sshObj.server.host}: Run exit" if @sshObj.debug
    #run the exit commands loaded by ssh and sudo su commands
    if @sshObj.exitCommands and @sshObj.exitCommands.length > 0
      @.emit 'msg', "#{@sshObj.server.host}: Queued exit commands: #{@sshObj.exitCommands.length}" if @sshObj.debug
      @command = @sshObj.exitCommands.pop()      
      @_connections[0].sessionText += "\n\n#{@sshObj.server.host}:#{@sshObj.sessionText}"
      @_runCommand(@command)
    #more hosts to connect to so process the next one
    else if @sshObj.hosts and @sshObj.hosts.length > 0
      @.emit 'msg', "#{@sshObj.server.host}: Next host from this host" if @sshObj.debug
      @.emit 'msg', @sshObj.hosts if @sshObj.verbose
      @_nextHost()
    #Leaving last host so load previous host
    else if @_connections and @_connections.length > 0
      @.emit 'msg', "#{@sshObj.server.host}: load previous host" if @sshObj.debug
      @_previousHost()
    #Nothing more to do so end the stream with last exit
    else
      @.emit 'msg', "#{@sshObj.server.host}: Exit command: Stream: close" if @sshObj.debug
      #@.command = "stream.end()"
      @_stream.close() #"exit#{@sshObj.enter}"

  _removeEvents: =>
    @.emit 'msg', "#{@sshObj.server.host}: Clearing previous event handlers" if @sshObj.debug
    @.removeListener 'commandProcessing', @onCommandProcessing
    @.removeListener 'commandComplete', @onCommandComplete
    @.removeListener 'commandTimeout',  @onCommandTimeout
    @.removeListener 'end', @onEnd

  _loadDefaults: (callback) =>
    @.emit 'msg', "#{@sshObj.server.host}: Load Defaults" if @sshObj.debug
    @sshObj.msg = { send: ( message ) =>
      console.log message
    } unless @sshObj.msg
    @sshObj.connectedMessage  = "Connected" unless @sshObj.connectedMessage
    @sshObj.readyMessage      = "Ready" unless @sshObj.readyMessage
    @sshObj.closedMessage     = "Closed" unless @sshObj.closedMessage
    @sshObj.showBanner        = false unless @sshObj.showBanner
    @sshObj.verbose           = false unless @sshObj.verbose
    @sshObj.debug             = false unless @sshObj.debug
    @sshObj.hosts             = [] unless @sshObj.hosts
    @sshObj.commands          = [] unless @sshObj.commands
    @sshObj.standardPrompt    = ">$%#" unless @sshObj.standardPrompt
    @sshObj.passwordPromt     = ":" unless @sshObj.passwordPromt
    @sshObj.passphrasePromt   = ":" unless @sshObj.passphrasePromt
    @sshObj.passPromptText    = "Password" unless @sshObj.passPromptText
    @sshObj.enter             = "\n" unless @sshObj.enter #windows = "\r\n", Linux = "\n", Mac = "\r"
    @sshObj.asciiFilter       = "[^\r\n\x20-\x7e]" unless @sshObj.asciiFilter
    @sshObj.disableColorFilter = false unless @sshObj.disableColorFilter is true
    @sshObj.disableASCIIFilter = false unless @sshObj.disableASCIIFilter is true
    @sshObj.textColorFilter   = "(\[{1}[0-9;]+m{1})" unless @sshObj.textColorFilter
    @sshObj.exitCommands      = [] unless @sshObj.exitCommands
    @sshObj.pwSent            = false
    @sshObj.sshAuth           = false
    @sshObj.server.hashKey    = @sshObj.server.hashKey ? ""
    @sshObj.sessionText       = "" unless @sshObj.sessionText
    @sshObj.streamEncoding    = @sshObj.streamEncoding ? "utf8"
    @sshObj.window            = true unless @sshObj.window
    @sshObj.pty               = true unless @sshObj.pty
    @idleTime                 = @sshObj.idleTimeOut ? 5000
    @asciiFilter              = new RegExp(@sshObj.asciiFilter,"g") unless @asciiFilter
    @textColorFilter          = new RegExp(@sshObj.textColorFilter,"g") unless @textColorFilter
    @passwordPromt            = new RegExp(@sshObj.passPromptText+".*" + @sshObj.passwordPromt + "\\s?$","i") unless @passwordPromt
    @passphrasePromt          = new RegExp(@sshObj.passPromptText+".*" + @sshObj.passphrasePromt + "\\s?$","i") unless @passphrasePromt
    @standardPrompt           = new RegExp("[" + @sshObj.standardPrompt + "]\\s?$") unless @standardPrompt
    @_callback                = @sshObj.callback if @sshObj.callback

    @onCommandProcessing      = @sshObj.onCommandProcessing ? ( command, response, sshObj, stream ) =>

    @onCommandComplete        = @sshObj.onCommandComplete ? ( command, response, sshObj ) =>
      @.emit 'msg', "#{@sshObj.server.host}: Class.commandComplete" if @sshObj.debug

    @onCommandTimeout         = @sshObj.onCommandTimeout ? ( command, response, stream, connection ) =>
      response = response.replace(@command, "")
      @.emit 'msg', "#{@sshObj.server.host}: Class.commandTimeout" if @sshObj.debug
      @.emit 'msg', "#{@sshObj.server.host}: Timeout command: #{command} response: #{response}" if @sshObj.verbose
      @_runExit()
      @.emit "error", "#{@sshObj.server.host}: Command timed out after #{@.idleTime/1000} seconds", "Timeout", true, (err, type)=>
        @sshObj.sessionText += @_buffer

    @onEnd                   = @sshObj.onEnd ? ( sessionText, sshObj ) =>
      @.emit 'msg', "#{@sshObj.server.host}: Class.end" if @sshObj.debug

    @.on "commandProcessing", @onCommandProcessing
    @.on "commandComplete", @onCommandComplete
    @.on "commandTimeout", @onCommandTimeout
    @.on "end", @onEnd

    if callback
      callback() 
    
  constructor: (hosts) ->
    if typeIsArray(hosts)
      @hosts = hosts
    else
      @hosts = [hosts]
    @connection = new require('ssh2')()

  _initiate: =>
    @.emit 'msg', "#{@sshObj.server.host}: initiate" if @sshObj.debug
    @.removeAllListeners()
    @connection.removeAllListeners()
    @_loadDefaults()
    #event handlers
    @.on "keyboard-interactive", ( name, instructions, instructionsLang, prompts, finish ) =>
      @.emit 'msg', "#{@sshObj.server.host}: Class.keyboard-interactive" if @sshObj.debug
      @.emit 'msg', "#{@sshObj.server.host}: Keyboard-interactive: finish([response, array]) not called in class event handler." if @sshObj.debug
      if @sshObj.verbose
        @.emit 'msg', "name: " + name
        @.emit 'msg', "instructions: " + instructions
        str = JSON.stringify(prompts, null, 4)
        @.emit 'msg', "Prompts object: " + str
      @sshObj.onKeyboardInteractive name, instructions, instructionsLang, prompts, finish if @sshObj.onKeyboardInteractive

    @.on "msg", @sshObj.msg.send ? ( message ) =>
      console.log message

    @.on "error", @sshObj.onError ? (err, type, close = false, callback) =>
      @.emit 'msg', "#{@sshObj.server.host}: Class.error" if @sshObj.debug
      if ( err instanceof Error )
        @.emit 'msg', "Error: " + err.message + ", Level: " + err.level
      else
        @.emit 'msg', "#{type} error: " + err
      callback(err, type) if callback
      @connection.end() if close

#    @._stream.on "pipe", @sshObj.onPipe ? (source) =>
#      @.emit 'msg', "#{@sshObj.server.host}: Class.pipe" if @sshObj.debug


#    @._stream.on "unpipe", @sshObj.onUnpipe ? (source) =>
#      @.emit 'msg', "#{@sshObj.server.host}: Class.unpipe" if @sshObj.debug

    @.on "data", @sshObj.onData ? (data) =>
      @.emit 'msg', "#{@sshObj.server.host}: data event"  if @sshObj.debug

    @.on "stderrData", @sshObj.onStderrData ? (data) =>
      console.error data

  connect: (callback)=>
    @_callback = callback if callback
    @_nextPrimaryHost()

  _nextPrimaryHost: =>
    @.emit 'msg', "#{@sshObj.server.host}: Current primary host" if @sshObj.debug

    host = @hosts.pop()
    @sshObj = host

    @.emit 'msg', "#{@sshObj.server.host}: Next primary host" if @sshObj.debug
    @_initiate()
    @_connect()

  _connect: =>
        @connection.on "keyboard-interactive", (name, instructions, instructionsLang, prompts, finish) =>
          @.emit 'msg', "#{@sshObj.server.host}: Connection.keyboard-interactive" if @sshObj.debug
          @.emit "keyboard-interactive", name, instructions, instructionsLang, prompts, finish

        @connection.on "connect", =>
          @.emit 'msg', "#{@sshObj.server.host}: Connection.connect" if @sshObj.debug
          @.emit 'msg', @sshObj.connectedMessage

        @connection.on "ready", =>
          @.emit 'msg', "#{@sshObj.server.host}: Connection.ready" if @sshObj.debug
          @.emit 'msg', @sshObj.readyMessage

          #open a shell
          @connection.shell @sshObj.window, { pty: @sshObj.pty }, (err, @_stream) =>
            if err instanceof Error
               @.emit 'error', err, "Shell", true
               return
            @.emit 'msg', "#{@sshObj.server.host}: Connection.shell" if @sshObj.debug
            @sshObj.sessionText = "Connected to #{@sshObj.server.host}#{@sshObj.enter}"
            @_stream.setEncoding(@sshObj.streamEncoding);

            @_stream.on "pipe", (source) =>
               emit "msg", "pipe for \n\n#{source}" if @sshObj.debug
               @.on "pipe", source

            @_stream.on "unpipe", (source) =>
               emit "msg", "unpipe for \n\n#{source}" if @sshObj.debug
               @.on "unpipe", source

            @_stream.on "error", (err) =>
              @.emit 'msg', "#{@sshObj.server.host}: Stream.error" if @sshObj.debug
              @.emit 'error', err, "Stream"

            @_stream.stderr.on 'data', (data) =>
              @.emit 'msg', "#{@sshObj.server.host}: Stream.stderr.data" if @sshObj.debug
              @.emit 'stderrData', data

            @_stream.on "data", (data)=>
              try
                @.emit 'data', data
                @_processData( data )
              catch e
                err = new Error("#{e} #{e.stack}")
                err.level = "Data handling"
                @.emit 'error', err, "Stream.read", true

            @_stream.on "pipe", (source)=>
              @.emit 'pipe', source

            @_stream.on "unpipe", (source)=>
              @.emit 'unpipe', source

            @_stream.on "finish", =>
              @.emit 'msg', "#{@sshObj.server.host}: Stream.finish" if @sshObj.debug
              @.emit 'end', @sshObj.sessionText, @sshObj
              @sshObj.commands = ""
              @_callback @sshObj.sessionText if @_callback

            @_stream.on "close", (code, signal) =>
              @.emit 'msg', "#{@sshObj.server.host}: Stream.close" if @sshObj.debug
              @connection.end()

        @connection.on "error", (err) =>
          @.emit 'msg', "#{@sshObj.server.host}: Connection.error" if @sshObj.debug
          @.emit "error", err, "Connection"

        @connection.on "close", (had_error) =>
          @.emit 'msg', "#{@sshObj.server.host}: Connection.close" if @sshObj.debug
          clearTimeout @sshObj.idleTimer if @sshObj.idleTimer
          if had_error
            @.emit "error", had_error, "Connection close"
          else
            @.emit 'msg', @sshObj.closedMessage
          if @hosts.length > 0
            @_nextPrimaryHost()

        if @sshObj.server and @sshObj.commands
          try
            @connection.connect
              host:             @sshObj.server.host
              port:             @sshObj.server.port
              forceIPv4:        @sshObj.server.forceIPv4
              forceIPv6:        @sshObj.server.forceIPv6
              hostHash:         @sshObj.server.hashMethod
              hostVerifier:     @sshObj.server.hostVerifier
              username:         @sshObj.server.userName
              password:         @sshObj.server.password
              agent:            @sshObj.server.agent
              agentForward:     @sshObj.server.agentForward
              privateKey:       @sshObj.server.privateKey
              passphrase:       @sshObj.server.passPhrase
              localHostname:    @sshObj.server.localHostname
              localUsername:    @sshObj.server.localUsername
              tryKeyboard:      @sshObj.server.tryKeyboard
              keepaliveInterval:@sshObj.server.keepaliveInterval
              keepaliveCountMax:@sshObj.server.keepaliveCountMax
              readyTimeout:     @sshObj.server.readyTimeout
              sock:             @sshObj.server.sock
              strictVendor:     @sshObj.server.strictVendor
              algorithms:       @sshObj.server.algorithms
              compress:         @sshObj.server.compress
              debug:            @sshObj.server.debug
          catch e
            @.emit 'error', "#{e} #{e.stack}", "Connection.connect", true
        else
          @.emit 'error', "Missing connection parameters", "Parameters", false, ( err, type, close ) ->
            @.emit 'msg', @sshObj.server
            @.emit 'msg', @sshObj.commands
        return @_stream


module.exports = SSH2Shell
