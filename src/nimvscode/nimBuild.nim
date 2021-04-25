import vscodeApi
import nimSuggestExec
import nimUtils
import jsNode
import jsNodeCp
import jsffi
import jsPromise
import jsNodeOs
import jsString
import jsre
import jsconsole
import sequtils
from nimProjects import getProjects, isProjectMode, getProjectFileInfo,
                        ProjectFileInfo, toLocalFile
from nimBinTools import getNimExecPath

type
  CheckStacktrace* = ref object
    file*: cstring
    line*: cint
    column*: cint
    msg*: cstring

  CheckResult* = ref object
    file*: cstring
    line*: cint
    column*: cint
    msg*: cstring
    severity*: cstring
    stacktrace*: seq[CheckStacktrace]

  ExecutorStatus = ref object
    initialized: bool
    process: ChildProcess
  
  Executors = JsAssoc[cstring, ExecutorStatus]

var executors = newJsAssoc[cstring, ExecutorStatus]()

proc resetExecutor(execs: Executors, projectPath: cstring) =
  ## have to reset these executors often enough, so made a template
  execs[projectPath] = ExecutorStatus{
        initialized: false,
        process: jsUndefined.to(ChildProcess)
    }

proc nimExec*(project: ProjectFileInfo, cmd: cstring,
              args: seq[cstring], useStdErr: bool): Future[cstring] =
  return newPromise(proc(
        resolve: proc(results: cstring),
        reject: proc(reason: JsObject)
    ) =
    console.log("nimExec - in proc")
    let execPath = getNimExecPath()
    if execPath.isNil() or execPath.strip() == "":
      resolve("")
      console.log("nimExec - no nim executable found")
      return

    let
      projectPath = toLocalFile(project)
      executorStatus = executors[projectPath]
      isExecutorReady = not executorStatus.isNil and executorStatus.initialized

    if isExecutorReady:
      let ps = executorStatus.process  
      if not ps.isNil:
        ps.kill("SIGKILL")
    
    executors.resetExecutor(projectPath)

    let
      spawnOptions = SpawnOptions{ cwd: project.wsFolder.uri.fsPath }
      executor = cp.spawn(execPath, @[cmd] & args, spawnOptions)
    executors[projectPath].process = executor
    executors[projectPath].initialized = true

    executor.onError(proc(error: ChildError): void =
      console.log("nimExec - onError", error)
      if not error.isNil and error.code == "ENOENT":
        vscode.window.showInformationMessage(
          "No nim binary could be found in PATH: '" & process.env["PATH"] & "'"
        )
        resolve("")
        return
    )

    executor.stdout.onData(proc(data: Buffer) =
      outputLine("[info] nim check output:\n" & data.toString())
    )

    var output: cstring = ""
    executor.onExit(proc(code: cint, signal: cstring) =
      if signal == "SIGKILL":
        reject(jsNull)
      else:
        try:
          executors.resetExecutor(projectPath)
          resolve(output)
        except:
          console.log("nimExec - onExit - failed to get output", getCurrentException())
          reject(getCurrentException().toJs())
    )

    let dataHandler = proc(data: Buffer) = output &= data.toString()
    if useStdErr:
      executor.stderr.onData(dataHandler)
    else:
      executor.stdout.onData(dataHandler)
  ).catch(proc(reason: JsObject): Promise[cstring] =
    return promiseReject(reason).toJs().to(Promise[cstring])
  )

proc nimCheckExec(
    project: ProjectFileInfo,
    args: seq[cstring],
    useStdErr: bool,
    cb: (proc(lines: seq[cstring]): seq[CheckResult])
): Future[seq[CheckResult]] {.async.} =
  try:
    var
      output = await nimExec(project, "check", args, useStdErr)
      split: seq[cstring] = output.split(nodeOs.eol)
    console.log("nimCheckExec - got some output: ", output, "split: ", split)
    if split.len == 1:
      # TODO - is this a bug by not using os.eol??
      var lfSplit = split[0].split("\n")
      if lfSplit.len > split.len:
        split = lfSplit

    return cb(split)
  except:
    console.error("nim check failed", getCurrentException())

proc parseErrors(lines: seq[cstring]): seq[CheckResult] =
  var
    messageText = ""
    stacktrace: seq[CheckStacktrace]

  # Progress indicator from nim CLI is just dots
  let
    dots = newRegExp(r"^\.+$")
    msgRegex = newRegExp(r"^([^(]*)?\((\d+)(,\s(\d+))?\)( (\w+):)? (.*)")
  for line in lines:
    let line = line.strip()

    if line.startsWith("Hint:") or line == "" or dots.test(line):
      continue

    let match = msgRegex.exec(line)
    if not match.toJs().to(bool):
      if messageText.len < 1024:
        messageText &= nodeOs.eol & line
    else:
      let
        file = match[1]
        lineStr = match[2]
        charStr = match[4]
        severity = match[6]
        msg = match[7]

      if severity == nil:
        stacktrace.add(CheckStacktrace(
          file: file,
          line: lineStr.parseCint(),
          column: charStr.parseCint(),
          msg: msg))
      else:
        if messageText.len > 0 and result.len > 0:
          result[^1].msg &= nodeOs.eol & messageText

        messageText = ""
        result.add(CheckResult(
          file: file,
          line: lineStr.parseCint(),
          column: charStr.parseCint(),
          msg: msg,
          severity: severity,
          stacktrace: stacktrace
        ))
        stacktrace.setLen(0)
  if messageText.len > 0 and result.len > 0:
    result[^1].msg &= nodeOs.eol & messageText

proc parseNimsuggestErrors(items: seq[NimSuggestResult]): seq[CheckResult] =
  var ret: seq[CheckResult] = @[]
  for item in items.filterIt(not (it.path == "???" and it.`type` == "Hint")):
    ret.add(CheckResult{
        file: item.path,
        line: item.line,
        column: item.column,
        msg: item.documentation,
        severity: item.`type`
    })

  console.log("parseNimsuggestErrors - return", ret)
  return ret

proc check*(filename: cstring, nimConfig: VscodeWorkspaceConfiguration): Promise[
    seq[CheckResult]] =
  var runningToolsPromises: seq[Promise[seq[CheckResult]]] = @[]

  if nimConfig.getBool("useNimsuggestCheck", false):
    runningToolsPromises.add(newPromise(proc(
                resolve: proc(values: seq[CheckResult]),
                reject: proc(reason: JsObject)
            ) = execNimSuggest(NimSuggestType.chk, filename, 0, 0, false).then(
                proc(items: seq[NimSuggestResult]) =
      if items.toJs().to(bool) and items.len > 0:
        resolve(parseNimsuggestErrors(items))
      else:
        resolve(@[])
    ).catch(proc(reason: JsObject) = reject(reason))
      )
    )
  else:
    var projects = if not isProjectMode(): newArray(getProjectFileInfo(filename))
      else: getProjects()

    for project in projects:
      runningToolsPromises.add(nimCheckExec(
          project,
          @["--listFullPaths".cstring, project.filePath],
          true,
          parseErrors
      ))

  return all(runningToolsPromises)
    .then(proc(resultSets: seq[seq[CheckResult]]): seq[CheckResult] =
      for rs in resultSets:
        result.add(rs)
  ).catch(proc(r: JsObject): Promise[seq[CheckResult]] =
    console.error("check - all - failed", r)
    promiseReject(r).toJs().to(Promise[seq[CheckResult]])
  )

var evalTerminal: VscodeTerminal

proc activateEvalConsole*(): void =
  vscode.window.onDidCloseTerminal(proc(e: VscodeTerminal) =
    if not evalTerminal.isNil() and e.processId == evalTerminal.processId:
      evalTerminal = jsUndefined.to(VscodeTerminal)
  )

proc selectTerminal(): Future[cstring] {.async.} =
  let items = newArrayWith[VscodeQuickPickItem](
    VscodeQuickPickItem{
      label: "nim",
      description: "Using `nim secret` command"
    },
    VscodeQuickPickItem{
      label: "inim",
      description: "Using `inim` command"
    }
  )
  var quickPick = await vscode.window.showQuickPick(items)
  return if quickPick.isNil(): jsUndefined.to(cstring) else: quickPick.label

proc nextLineWithTextIdentation(startOffset: cint, tmp: seq[cstring]): cint =
  for i in startOffset..<tmp.len:
    # Empty lines are ignored
    if tmp[i] == "": continue

    # Spaced line, this is indented
    var m = tmp[i].match(newRegExp(r"^ *"))
    if m.toJs().to(bool) and m[0].len > 0:
      return cint(m[0].len)

    # Normal line without identation
    break
  return 0

proc maintainIndentation(text: cstring): cstring =
  var tmp = text.split(newRegExp(r"\r?\n"))

  if tmp.len <= 1:
    return text

  # if previous line is indented, this line is empty
  # and next line with text is indented then this line should be indented
  for i in 0..(tmp.len - 2):
    # empty line
    if tmp[i].len == 0:
      var spaces = nextLineWithTextIdentation(cint(i + 1), tmp)
      # Further down, there is an indented line, so this empty line
      # should be indented
      if spaces > 0:
        tmp[i] = cstring(" ").repeat(spaces)

  return tmp.join("\n")

proc execSelectionInTerminal*(#[ doc:VscodeTextDocument ]#) {.async.} =
  var activeEditor = vscode.window.activeTextEditor
  if not activeEditor.isNil():
    var selection = activeEditor.selection
    var document = activeEditor.document
    var text = if selection.isEmpty:
                document.lineAt(selection.active.line).text
            else:
                document.getText(selection)

    if evalTerminal.isNil():
      # select type of terminal
      var executable = await selectTerminal()

      if executable.isNil():
        return

      var execPath = getNimExecPath(executable)
      evalTerminal = vscode.window.createTerminal("Nim Console")
      evalTerminal.show(preserveFocus = true)
      # previously was a setTimeout 3s, perhaps a valid pid works better
      discard await evalTerminal.processId

      if executable == "nim":
        evalTerminal.sendText(execPath & " secret\n")
      elif executable == "inim":
        evalTerminal.sendText(execPath & " --noAutoIndent\n")

    evalTerminal.sendText(maintainIndentation(text))
    evalTerminal.sendText("\n")
