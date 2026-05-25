on run argv
  if (count of argv) is not 3 then error "usage: finder_operation.applescript <finder-copy|finder-move> <source-path> <target-dir>"

  set opName to item 1 of argv
  set sourcePath to item 2 of argv
  set targetDirPath to item 3 of argv
  set sourceAlias to POSIX file sourcePath as alias
  set targetDirAlias to POSIX file targetDirPath as alias

  tell application "Finder"
    if opName is "finder-copy" then
      duplicate sourceAlias to targetDirAlias with replacing
    else if opName is "finder-move" then
      move sourceAlias to targetDirAlias with replacing
    else
      error "unknown Finder operation: " & opName
    end if
  end tell
end run
