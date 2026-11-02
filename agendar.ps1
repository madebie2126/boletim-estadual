# Cria (ou atualiza) a tarefa diária no Agendador de Tarefas do Windows.
# Rode uma vez:  powershell -ExecutionPolicy Bypass -File .\agendar.ps1

$base = $PSScriptRoot
$cfg = Get-Content "$base\config.json" -Raw -Encoding UTF8 | ConvertFrom-Json

$acao = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$base\robo.ps1`"" `
  -WorkingDirectory $base
$gatilho = New-ScheduledTaskTrigger -Daily -At $cfg.agendamento_hora
$ajustes = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName 'Robo Leis Estaduais' -Action $acao -Trigger $gatilho -Settings $ajustes `
  -Description 'Envia por e-mail o resumo diário de leis e decisões estaduais' -Force | Out-Null

Write-Host "Tarefa 'Robo Leis Estaduais' agendada para todo dia às $($cfg.agendamento_hora)."
Write-Host "Se o PC estiver desligado nesse horário, ela roda assim que ele ligar."
