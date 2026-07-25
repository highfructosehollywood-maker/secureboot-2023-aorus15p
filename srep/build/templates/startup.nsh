@echo -off
cls

for %i run (0 5)
  fs%i:
  if exist "@SREP_EFI@" then
    bcfg driver add 0 @SREP_EFI@ "SREP driver"
    bcfg driver dump
    echo " "
    echo "Added a new entry to DriverOrder, you may reboot the pc"
    goto END
  else
    echo "Couldn't find @SREP_EFI@ on FS"
    echo %i
    echo " "
  endif
endfor

:END
