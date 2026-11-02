# Senso Comum
# A cada 15 dias escolhe um tema da biblioteca, lê SÓ as fontes cadastradas para ele e escreve
# um rascunho "o que dizem × o que os dados mostram", mais um kit para explicar o assunto.
# Nada vai para o site sem aprovação: na nuvem o rascunho vira uma proposta (pull request).
#
# Uso:
#   .\senso-comum.ps1                          -> escolhe o tema e grava o rascunho em docs\
#   .\senso-comum.ps1 -Tema bolsa-familia      -> usa esse tema da biblioteca
#   .\senso-comum.ps1 -Simular                 -> grava em previa-senso\ (o site não muda)
#   .\senso-comum.ps1 -Avisar -LinkRevisao URL -> envia o e-mail de revisão (usado pela nuvem)

param([string]$Tema = '', [switch]$Simular, [switch]$Avisar, [string]$LinkRevisao = '')

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$base = $PSScriptRoot
$pastaTrabalho = "$base\.senso"

function Ler-Json($caminho) { Get-Content $caminho -Raw -Encoding UTF8 | ConvertFrom-Json }
function Gravar($caminho, $texto) { [IO.File]::WriteAllText($caminho, $texto, (New-Object Text.UTF8Encoding $false)) }
function Html($s) { [Net.WebUtility]::HtmlEncode([string]$s) }

function Log($msg) {
  $linha = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [senso] $msg"
  Write-Host $linha
  Add-Content -Path "$base\robo.log" -Value $linha -Encoding UTF8
}

$cfg = Ler-Json "$base\config.json"
$seg = if (Test-Path "$base\segredos.json") { Ler-Json "$base\segredos.json" } else {
  [pscustomobject]@{ email_conta = $env:EMAIL_CONTA; email_destinatario = $env:EMAIL_DESTINATARIO; senha_email = $env:SENHA_EMAIL; chave_gemini = $env:CHAVE_GEMINI }
}
$emailConta = $seg.email_conta
$emailPara = if ($seg.email_destinatario) { $seg.email_destinatario } else { $emailConta }

function Enviar-Email($assunto, $html) {
  $smtp = New-Object Net.Mail.SmtpClient($cfg.email.servidor_smtp, [int]$cfg.email.porta)
  $smtp.EnableSsl = $true
  $smtp.Credentials = New-Object Net.NetworkCredential($emailConta, $seg.senha_email)
  $msg = New-Object Net.Mail.MailMessage
  $msg.From = $emailConta
  foreach ($para in ($emailPara -split '[,;]')) { if ($para.Trim()) { $msg.To.Add($para.Trim()) } }
  $msg.Subject = $assunto
  $msg.SubjectEncoding = [Text.Encoding]::UTF8
  $msg.Body = $html
  $msg.BodyEncoding = [Text.Encoding]::UTF8
  $msg.IsBodyHtml = $true
  $smtp.Send($msg)
}

# ---------- Modo aviso: só manda o e-mail de revisão que a geração deixou pronto ----------
if ($Avisar) {
  $html = [IO.File]::ReadAllText("$pastaTrabalho\email.html", [Text.Encoding]::UTF8).Replace('{{LINK_REVISAO}}', $LinkRevisao)
  $titulo = [IO.File]::ReadAllText("$pastaTrabalho\titulo.txt", [Text.Encoding]::UTF8).Trim()
  Enviar-Email "Senso Comum para revisar: $titulo" $html
  Log "E-mail de revisão enviado."
  return
}

# ---------- 1. Tema ----------
$biblioteca = @(Get-ChildItem "$base\biblioteca\*.json" | ForEach-Object { Ler-Json $_.FullName })
$publicados = if (Test-Path "$base\docs\senso-comum.json") { @(Ler-Json "$base\docs\senso-comum.json") } else { @() }

# Manchetes da quinzena, para sugerir temas e escolher o mais atual
$limite = (Get-Date).AddDays(-15).ToString('yyyy-MM-dd')
$manchetes = @()
if (Test-Path "$base\docs\edicoes.json") {
  $manchetes = @((Ler-Json "$base\docs\edicoes.json") | Where-Object { $_.dia -ge $limite } | ForEach-Object { $_.manchetes })
}

if ($Tema) {
  $escolhido = $biblioteca | Where-Object { $_.slug -eq $Tema } | Select-Object -First 1
  if (-not $escolhido) { throw "Tema '$Tema' não existe na biblioteca. Disponíveis: $(($biblioteca.slug) -join ', ')" }
} else {
  # Sem tema pedido: o que foi publicado há mais tempo (ou nunca)
  $escolhido = $biblioteca | Sort-Object { $s = $_.slug; ($publicados | Where-Object { $_.slug -eq $s } | Sort-Object dia -Descending | Select-Object -First 1).dia } | Select-Object -First 1
}
Log "Tema: $($escolhido.tema)"

# ---------- 2. Fontes ----------
function Texto-De-Html($h) {
  $h = $h -replace '(?is)<(script|style|noscript|svg|header|footer|nav|form)\b[^>]*>.*?</\1>', ' '
  $t = [Net.WebUtility]::HtmlDecode(($h -replace '<[^>]+>', ' '))
  ($t -replace '\s+', ' ').Trim()
}

$partes = New-Object System.Collections.Generic.List[object]
$textos = @{}
$tipos = @{}
for ($i = 0; $i -lt $escolhido.fontes.Count; $i++) {
  $f = $escolhido.fontes[$i]
  try {
    $r = Invoke-WebRequest -Uri $f.url -UseBasicParsing -TimeoutSec 60 -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
    $bytes = $r.RawContentStream.ToArray()
    if ([string]$r.Headers['Content-Type'] -match 'pdf') {
      $partes.Add(@{ text = "FONTE [$i]: $($f.titulo) — $($f.orgao). Documento PDF a seguir." })
      $partes.Add(@{ inline_data = @{ mime_type = 'application/pdf'; data = [Convert]::ToBase64String($bytes) } })
      $tipos[$i] = 'pdf'
    } else {
      $texto = Texto-De-Html ([Text.Encoding]::UTF8.GetString($bytes))
      if ($texto.Length -gt 20000) { $texto = $texto.Substring(0, 20000) }
      $partes.Add(@{ text = "FONTE [$i]: $($f.titulo) — $($f.orgao).`n$texto" })
      $textos[$i] = $texto
      $tipos[$i] = 'html'
    }
  } catch {
    Log "Fonte indisponível [$i] $($f.url): $($_.Exception.Message)"
    $tipos[$i] = 'indisponivel'
  }
}
Log "Fontes lidas: $(@($tipos.Values | Where-Object { $_ -ne 'indisponivel' }).Count) de $($escolhido.fontes.Count)"

# ---------- 3. Rascunho com IA ----------
$instrucoes = @"
Você escreve a seção "Senso Comum" de um boletim de educação política. O objetivo é mostrar, com dados e em linguagem muito simples, por que algumas frases que todo mundo repete não se sustentam, e explicar QUEM DECIDE de verdade cada coisa (município, estado ou União), para as pessoas votarem com mais cuidado em todos os níveis.

TOM: didático, acolhedor, sem juridiquês e sem lado partidário. Nunca ataque quem pensa diferente nem cite partidos ou políticos como heróis ou vilões. Frases curtas. Explique siglas.

TEMA: $($escolhido.tema)
FRASES DO SENSO COMUM: $(($escolhido.senso_comum | ForEach-Object { "`"$_`"" }) -join ' | ')
DICA SOBRE QUEM DECIDE (confira com as fontes): $($escolhido.dica_quem_decide)

REGRAS DE DADOS (as mais importantes):
1. Use APENAS informações que estão nas FONTES numeradas que vêm a seguir. Não use nada que você saiba por fora.
2. Todo dado com número precisa de "fonte" (o número da fonte) e "trecho": uma cópia LITERAL e curta (até 25 palavras) do texto da fonte que comprova o dado, no idioma original da fonte.
3. Não arredonde para cima, não generalize e não transforme estimativa em certeza. Se é estimativa de modelo ou associação estatística, diga isso de forma simples.
4. Se as fontes não sustentam rebater alguma frase, diga isso com honestidade em "ressalvas". É melhor admitir um limite do que exagerar.
5. Nos campos "resposta", "chamada" e no kit, afirme SOMENTE o que está nos "dados" que você listou. Nenhum fato a mais, nenhuma explicação de causa que a fonte não dê (ex.: não diga que uma regra específica do programa causou um resultado se a fonte fala do programa como um todo).
6. Evite palavras absolutas como "comprova", "prova", "sempre", "nunca", "ninguém". Prefira "os estudos não encontraram", "os dados indicam", "a pesquisa estimou".
7. Regras de programas e valores mudam com o tempo. Ao citar uma regra, um valor ou uma estatística, diga o ano a que ela se refere (ex.: "em 2024, a regra permitia..."). Nunca apresente como atual uma regra que vem de fonte antiga.
8. Em "nao_dizer", traga pelo menos 3 itens.
9. Nos textos, nunca cite fontes por número; quando precisar, cite pelo nome (ex.: "o estudo do Ipea").

Também recebeu manchetes recentes do boletim. Use-as SOMENTE para sugerir próximos temas de senso comum.
MANCHETES DA QUINZENA: $(($manchetes | Select-Object -First 40) -join ' | ')

Responda SOMENTE com JSON neste formato:
{
 "titulo": "a frase do senso comum em forma de pergunta curta",
 "chamada": "1 frase com a resposta curta",
 "mitos": [ { "frase": "a frase como as pessoas falam", "resposta": "2 ou 3 frases simples", "dados": [ { "dado": "frase curta com o dado", "fonte": 0, "trecho": "cópia literal da fonte" } ] } ],
 "quem_decide": { "nivel": "ex.: União, com as prefeituras", "explicacao": "2 frases simples" },
 "e_o_voto": "2 frases: o que observar ao votar em cada nível (vereador, prefeito, deputado, governador, presidente) sobre este tema",
 "ressalvas": [ "limites dos dados, cuidados" ],
 "kit": {
   "resumo": [ "frase 1", "frase 2", "frase 3" ],
   "palavras": [ { "dificil": "termo técnico", "simples": "como dizer de forma simples" } ],
   "jeitos": [
     { "estilo": "Comparação do dia a dia", "texto": "..." },
     { "estilo": "Número que surpreende", "texto": "..." },
     { "estilo": "Pergunta de volta", "texto": "..." }
   ],
   "nao_dizer": [ "afirmações exageradas que podem ser usadas contra você, e o que dizer no lugar" ]
 },
 "sugestoes_proximos": [ { "tema": "...", "frase": "frase de senso comum ligada a isso", "por_que_agora": "1 frase" } ]
}
"@

function Gemini-Json($partesPedido, $temperatura) {
  $corpo = @{
    contents = @(@{ parts = @($partesPedido) })
    generationConfig = @{ responseMimeType = 'application/json'; temperature = $temperatura }
  } | ConvertTo-Json -Depth 10
  for ($tentativa = 1; $tentativa -le 3; $tentativa++) {
    try {
      $r = Invoke-WebRequest -Uri "https://generativelanguage.googleapis.com/v1beta/models/$($cfg.ia.modelo_gemini):generateContent" -Method POST `
        -Headers @{ 'x-goog-api-key' = $seg.chave_gemini } -Body ([Text.Encoding]::UTF8.GetBytes($corpo)) `
        -ContentType 'application/json; charset=utf-8' -UseBasicParsing -TimeoutSec 600
      $texto = (([Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())) | ConvertFrom-Json).candidates[0].content.parts[0].text
      return ($texto.Substring($texto.IndexOf('{'), $texto.LastIndexOf('}') - $texto.IndexOf('{') + 1) | ConvertFrom-Json)
    } catch {
      Log "Chamada à IA falhou (tentativa $tentativa): $($_.Exception.Message)"
      # A faixa gratuita limita chamadas por minuto: espera antes de tentar de novo
      if ($tentativa -lt 3) { Start-Sleep -Seconds (40 * $tentativa) }
    }
  }
  return $null
}

$partes.Insert(0, @{ text = $instrucoes })
$rascunho = Gemini-Json $partes.ToArray() 0.2
if (-not $rascunho) { throw 'A IA não conseguiu escrever o rascunho.' }
New-Item -ItemType Directory -Force -Path $pastaTrabalho | Out-Null
Gravar "$pastaTrabalho\ia_rascunho_1.json" ($rascunho | ConvertTo-Json -Depth 10)

# ---------- 4. Conferência ----------
$alertas = New-Object System.Collections.Generic.List[string]

# 4a. Revisor: aponta frases que dizem mais do que os dados sustentam
function Revisar($rasc) {
  $pedido = @"
Você é um revisor rigoroso de checagem de fatos. Abaixo está um rascunho em JSON. A lista "dados" de cada mito é a ÚNICA base factual permitida.
Leia "titulo", "chamada", cada "resposta", "quem_decide", "e_o_voto" e todo o "kit". Aponte cada frase que afirma algo que NÃO está nos dados: fato novo, generalização (ex.: falar de "a maioria dos beneficiários" quando o dado é sobre vagas), relação de causa não sustentada, número diferente do dado, ou regra apresentada como atual sem ano. Aponte também frases repetidas ou sem sentido.
Não aponte explicações de siglas, perguntas retóricas, comparações claramente ilustrativas nem arredondamentos honestos (ex.: "713 mil" para 713.083).
Em "quem_decide" e "e_o_voto" também é base permitida esta explicação sobre quem decide (não aponte o que estiver de acordo com ela): $($escolhido.dica_quem_decide)
Responda SOMENTE com JSON: {"problemas":[{"frase":"trecho do rascunho","motivo":"por que vai além dos dados","sugestao":"como reescrever fiel aos dados"}]}. Se estiver tudo certo, {"problemas":[]}.

RASCUNHO:
$($rasc | ConvertTo-Json -Depth 10)
"@
  $res = Gemini-Json @(@{ text = $pedido }) 0
  if ($res -eq $null) { return $null }
  return @($res.problemas)
}

$problemas = Revisar $rascunho
$corrigidas = 0
if ($problemas -ne $null -and $problemas.Count -gt 0) {
  # 4b. Reescreve o rascunho inteiro corrigindo os pontos, sem tocar nos dados
  $pedido = @"
Reescreva o rascunho abaixo corrigindo TODOS os problemas apontados pelo revisor. Regras:
- Mantenha exatamente o mesmo formato JSON e os mesmos campos.
- NÃO altere a lista "dados" de nenhum mito (copie igual) nem "sugestoes_proximos".
- Os textos devem afirmar somente o que está nos dados. Escreva frases naturais e simples; nunca inclua instruções, comentários ou observações do revisor no texto.
- Não repita frases.

PROBLEMAS:
$($problemas | ConvertTo-Json -Depth 5)

RASCUNHO:
$($rascunho | ConvertTo-Json -Depth 10)
"@
  $novo = Gemini-Json @(@{ text = $pedido }) 0.1
  if ($novo -and @($novo.mitos).Count -eq @($rascunho.mitos).Count -and $novo.kit) {
    # Os dados conferidos continuam sendo os da primeira versão
    for ($i = 0; $i -lt @($novo.mitos).Count; $i++) { $novo.mitos[$i].dados = $rascunho.mitos[$i].dados }
    $novo.sugestoes_proximos = $rascunho.sugestoes_proximos
    $rascunho = $novo
    $corrigidas = $problemas.Count
    $problemas = Revisar $rascunho
  } else {
    Log 'A reescrita não veio no formato esperado; mantendo a primeira versão.'
  }
}
if ($problemas -eq $null) { $alertas.Add('A revisão automática falhou; leia o texto com atenção redobrada.') }
else { foreach ($p in $problemas) { $alertas.Add("PODE IR ALÉM DOS DADOS: `"$($p.frase)`" — $($p.motivo) Sugestão: $($p.sugestao)") } }

# 4c. Cada dado traz um trecho literal; confere se ele está mesmo no texto da fonte citada
function Normalizar($s) { (([string]$s).ToLower() -replace '[^\p{L}\p{N}]', '') }
foreach ($m in $rascunho.mitos) {
  foreach ($d in $m.dados) {
    $n = [int]$d.fonte
    $status = if ($n -lt 0 -or $n -ge $escolhido.fontes.Count -or $tipos[$n] -eq 'indisponivel') { 'sem_fonte' }
              elseif ($tipos[$n] -eq 'pdf') { 'pdf' }
              elseif ((Normalizar $textos[$n]).Contains((Normalizar $d.trecho))) { 'ok' }
              else { 'nao_encontrado' }
    $d | Add-Member -NotePropertyName status -NotePropertyValue $status -Force
    switch ($status) {
      'sem_fonte' { $alertas.Add("SEM FONTE VÁLIDA: `"$($d.dado)`" — não publique sem conferir.") }
      'nao_encontrado' { $alertas.Add("TRECHO NÃO ENCONTRADO na fonte [$($n + 1)]: `"$($d.dado)`" — confira se o número está certo.") }
      'pdf' { $alertas.Add("Confira no PDF da fonte [$($n + 1)]: `"$($d.dado)`" (trecho: `"$($d.trecho)`").") }
    }
  }
}
Gravar "$pastaTrabalho\ia_rascunho_final.json" ($rascunho | ConvertTo-Json -Depth 10)
$avisoRevisor = if ($corrigidas -gt 0) { "O revisor automático encontrou e corrigiu $corrigidas frase(s) que iam além dos dados antes de te enviar." } else { '' }
Log "Conferência: $corrigidas frase(s) corrigidas pelo revisor; $(@($rascunho.mitos.dados | Where-Object { $_.status -eq 'ok' }).Count) dado(s) confirmados no texto; $($alertas.Count) alerta(s) para você."

# ---------- 5. Página do site ----------
$cor = @{ fundo = '#eef1f5'; azul = '#12355b'; destaque = '#2f7fd8'; texto = '#1f2933'; suave = '#6b7785'; borda = '#dde3ea'; verde = '#1a7f37'; creme = '#f5f8fc'; laranja = '#c2410c'; pessego = '#fff4ed' }
$dia = Get-Date -Format 'yyyy-MM-dd'
$diasSemana = 'domingo', 'segunda-feira', 'terça-feira', 'quarta-feira', 'quinta-feira', 'sexta-feira', 'sábado'
$dataExtenso = "$($diasSemana[[int](Get-Date).DayOfWeek]), $(Get-Date -Format 'dd/MM/yyyy')"
$arquivoPagina = "$dia-$($escolhido.slug).html"

function Ref($d) { "<a href='#fonte-$([int]$d.fonte + 1)' target='_self' style='color:$($cor.destaque);text-decoration:none;font-size:12px'>[$([int]$d.fonte + 1)]</a>" }

function Corpo-Artigo($prefixo) {
  $cards = foreach ($m in $rascunho.mitos) {
    $dados = ($m.dados | ForEach-Object { "<li style='margin:6px 0'>$(Html $_.dado) $(Ref $_)</li>" }) -join ''
    @"
<div style='background:#fff;border:1px solid $($cor.borda);border-left:4px solid $($cor.laranja);border-radius:8px;padding:18px 20px;margin:0 0 14px'>
  <div style='font-size:11px;font-weight:bold;letter-spacing:.8px;color:$($cor.laranja)'>O QUE DIZEM</div>
  <div style='font-size:18px;line-height:1.35;font-style:italic;color:$($cor.texto);margin:4px 0 12px'>&ldquo;$(Html $m.frase)&rdquo;</div>
  <div style='font-size:11px;font-weight:bold;letter-spacing:.8px;color:$($cor.destaque)'>O QUE OS DADOS MOSTRAM</div>
  <div style='font-size:15px;line-height:1.55;color:$($cor.texto);margin-top:4px'>$(Html $m.resposta)</div>
  <ul style='font-size:14px;line-height:1.5;color:$($cor.texto);margin:10px 0 0;padding-left:20px'>$dados</ul>
</div>
"@
  }
  $ressalvas = ($rascunho.ressalvas | ForEach-Object { "<li style='margin:4px 0'>$(Html $_)</li>" }) -join ''
  $fontes = for ($i = 0; $i -lt $escolhido.fontes.Count; $i++) {
    $f = $escolhido.fontes[$i]
    "<li id='fonte-$($i + 1)' style='margin:6px 0'><a href='$(Html $f.url)' style='color:$($cor.destaque);text-decoration:none'>$(Html $f.titulo)</a> <span style='color:$($cor.suave)'>— $(Html $f.orgao)</span></li>"
  }
  @"
<div style='background:$($cor.azul);border-radius:10px;padding:24px;margin-bottom:18px'>
  <div style='font-size:11px;font-weight:bold;letter-spacing:2px;color:#ffb38a'>SENSO COMUM</div>
  <div style='font-size:24px;line-height:1.25;font-weight:bold;color:#fff;margin-top:6px'>$(Html $rascunho.titulo)</div>
  <div style='font-size:15px;line-height:1.5;color:#d6e4f5;margin-top:8px'>$(Html $rascunho.chamada)</div>
  <div style='font-size:12px;color:#9fc3ee;margin-top:10px'>$dataExtenso</div>
</div>
$($cards -join "`n")
<div style='background:#fff;border:1px solid $($cor.borda);border-left:4px solid $($cor.azul);border-radius:8px;padding:18px 20px;margin:0 0 14px'>
  <span style='display:inline-block;background:$($cor.azul);color:#fff;font-size:10px;font-weight:bold;letter-spacing:.6px;padding:2px 8px;border-radius:10px'>QUEM DECIDE: $(Html ([string]$rascunho.quem_decide.nivel).ToUpper())</span>
  <div style='font-size:15px;line-height:1.55;color:$($cor.texto);margin-top:8px'>$(Html $rascunho.quem_decide.explicacao)</div>
</div>
<div style='background:$($cor.creme);border:1px solid $($cor.borda);border-radius:8px;padding:18px 20px;margin:0 0 14px'>
  <div style='font-size:11px;font-weight:bold;letter-spacing:.8px;color:$($cor.azul)'>E O SEU VOTO?</div>
  <div style='font-size:15px;line-height:1.55;color:$($cor.texto);margin-top:4px'>$(Html $rascunho.e_o_voto)</div>
</div>
<div style='padding:6px 4px 0;font-size:13px;line-height:1.5;color:$($cor.suave)'>
  <b>Limites e cuidados</b><ul style='margin:6px 0 14px;padding-left:20px'>$ressalvas</ul>
  <b>Fontes</b><ol style='margin:6px 0 0;padding-left:20px'>$($fontes -join '')</ol>
</div>
"@
}

function Pagina-Site($conteudo, $titulo, $prefixo) {
  @"
<!DOCTYPE html>
<html lang='pt-BR'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>
<title>$(Html $titulo) · Senso Comum</title><meta name='description' content='$(Html $rascunho.chamada)'>
<meta property='og:title' content='$(Html $titulo)'><meta property='og:description' content='$(Html $rascunho.chamada)'>
<meta name='theme-color' content='$($cor.azul)'><link rel='manifest' href='${prefixo}manifest.webmanifest'>
<link rel='icon' href='${prefixo}icone.svg' type='image/svg+xml'><link rel='apple-touch-icon' href='${prefixo}icone-180.png'><base target='_blank'></head>
<body style='margin:0;padding:24px 12px;background:$($cor.fundo);font-family:Segoe UI,Helvetica,Arial,sans-serif'>
<div style='max-width:640px;margin:0 auto'>
  <div style='padding:0 4px 12px;font-size:13px'><a href='${prefixo}index.html' target='_self' style='color:$($cor.azul);font-weight:bold;text-decoration:none'>Boletim Estadual</a><span style='float:right'><a href='${prefixo}index.html' target='_self' style='color:$($cor.destaque);text-decoration:none'>Hoje</a> &nbsp;·&nbsp; <a href='${prefixo}senso-comum.html' target='_self' style='color:$($cor.destaque);text-decoration:none'>Senso Comum</a> &nbsp;·&nbsp; <a href='${prefixo}arquivo.html' target='_self' style='color:$($cor.destaque);text-decoration:none'>Edições anteriores</a></span></div>
  $conteudo
</div>
</body></html>
"@
}

$pastaSite = if ($Simular) { "$base\previa-senso" } else { "$base\docs" }
New-Item -ItemType Directory -Force -Path "$pastaSite\senso-comum", $pastaTrabalho | Out-Null
Gravar "$pastaSite\senso-comum\$arquivoPagina" (Pagina-Site (Corpo-Artigo '../') $rascunho.titulo '../')

# Índice do Senso Comum
$lista = @([pscustomobject]@{ dia = $dia; slug = $escolhido.slug; titulo = $rascunho.titulo; chamada = $rascunho.chamada; arquivo = "senso-comum/$arquivoPagina" }) +
  @($publicados | Where-Object { $_.arquivo -ne "senso-comum/$arquivoPagina" }) | Sort-Object dia -Descending
Gravar "$pastaSite\senso-comum.json" (ConvertTo-Json -InputObject @($lista) -Depth 5)
$itensIndice = foreach ($p in $lista) {
  "<a href='$($p.arquivo)' target='_self' style='display:block;text-decoration:none;background:#fff;border:1px solid $($cor.borda);border-left:4px solid $($cor.laranja);border-radius:8px;padding:16px 20px;margin:0 0 12px'><div style='font-size:17px;font-weight:bold;color:$($cor.texto)'>$(Html $p.titulo)</div><div style='font-size:14px;line-height:1.5;color:$($cor.suave);margin-top:4px'>$(Html $p.chamada)</div></a>"
}
$cabecalhoIndice = "<div style='background:$($cor.azul);border-radius:10px;padding:22px 24px;margin-bottom:18px'><div style='font-size:11px;font-weight:bold;letter-spacing:2px;color:#ffb38a'>SENSO COMUM</div><div style='font-size:22px;font-weight:bold;color:#fff;margin-top:6px'>O que todo mundo repete × o que os dados mostram</div><div style='font-size:14px;color:#d6e4f5;margin-top:6px'>A cada 15 dias, uma frase do dia a dia explicada com fontes, e quem decide de verdade sobre o assunto.</div></div>"
Gravar "$pastaSite\senso-comum.html" (Pagina-Site ($cabecalhoIndice + ($itensIndice -join "`n")) 'Senso Comum' '')

# ---------- 6. Kit para explicar + e-mail de revisão ----------
$alertasHtml = if ($alertas.Count -gt 0) {
  "<div style='background:#fff7e6;border:1px solid #f0c36d;border-radius:8px;padding:14px 18px;margin:0 0 16px'><b style='color:#8a5a00'>Confira antes de aprovar</b><ul style='margin:6px 0 0;padding-left:20px;font-size:13px;line-height:1.5'>$(($alertas | ForEach-Object { "<li>$(Html $_)</li>" }) -join '')</ul></div>"
} else { "<div style='background:#eaf6ee;border:1px solid #9fd3ad;border-radius:8px;padding:12px 18px;margin:0 0 16px;font-size:13px'>Todos os dados foram encontrados nas fontes citadas.</div>" }
if ($avisoRevisor) { $alertasHtml = "<div style='font-size:13px;color:$($cor.verde);margin:0 0 8px'>&#10003; $(Html $avisoRevisor)</div>" + $alertasHtml }

$k = $rascunho.kit
$kitHtml = @"
<div style='background:#fff;border:1px solid $($cor.borda);border-radius:8px;padding:18px 20px;margin:0 0 16px'>
  <div style='font-size:13px;font-weight:bold;letter-spacing:1px;color:$($cor.laranja)'>KIT PARA EXPLICAR</div>
  <div style='margin-top:10px;font-weight:bold'>Resumo em 3 frases</div>
  <ol style='margin:4px 0 0;padding-left:20px;line-height:1.5'>$(($k.resumo | ForEach-Object { "<li>$(Html $_)</li>" }) -join '')</ol>
  <div style='margin-top:12px;font-weight:bold'>Troque o difícil pelo simples</div>
  <ul style='margin:4px 0 0;padding-left:20px;line-height:1.5'>$(($k.palavras | ForEach-Object { "<li><s style='color:$($cor.suave)'>$(Html $_.dificil)</s> → <b>$(Html $_.simples)</b></li>" }) -join '')</ul>
  <div style='margin-top:12px;font-weight:bold'>Jeitos de explicar</div>
  $(($k.jeitos | ForEach-Object { "<div style='background:$($cor.creme);border-radius:6px;padding:10px 12px;margin:6px 0'><div style='font-size:11px;font-weight:bold;letter-spacing:.6px;color:$($cor.azul)'>$(Html ([string]$_.estilo).ToUpper())</div><div style='margin-top:2px;line-height:1.5'>$(Html $_.texto)</div></div>" }) -join '')
  <div style='margin-top:12px;font-weight:bold'>O que NÃO dizer</div>
  <ul style='margin:4px 0 0;padding-left:20px;line-height:1.5'>$(($k.nao_dizer | ForEach-Object { "<li>$(Html $_)</li>" }) -join '')</ul>
</div>
"@
$sugestoesHtml = "<div style='font-size:13px;line-height:1.5;color:$($cor.suave);margin:0 0 16px'><b>Ideias para os próximos</b> (pede pro Claude montar as fontes de qualquer um):<ul style='margin:4px 0 0;padding-left:20px'>$(($rascunho.sugestoes_proximos | ForEach-Object { "<li><b>$(Html $_.tema)</b>: &ldquo;$(Html $_.frase)&rdquo; — $(Html $_.por_que_agora)</li>" }) -join '')</ul></div>"
$botao = "<a href='{{LINK_REVISAO}}' style='display:inline-block;background:$($cor.verde);color:#fff;font-weight:bold;text-decoration:none;padding:12px 20px;border-radius:8px;margin:4px 0 18px'>Revisar e aprovar no GitHub</a>"

$emailHtml = @"
<!DOCTYPE html><html lang='pt-BR'><head><meta charset='utf-8'></head>
<body style='margin:0;padding:24px 12px;background:$($cor.fundo);font-family:Segoe UI,Helvetica,Arial,sans-serif;color:$($cor.texto)'>
<div style='max-width:640px;margin:0 auto'>
  <div style='font-size:20px;font-weight:bold;margin-bottom:6px'>Senso Comum pronto para revisar</div>
  <div style='font-size:14px;color:$($cor.suave);margin-bottom:12px'>Nada foi publicado. Leia, confira os alertas e aprove pelo GitHub (botão “Merge pull request”). Para pedir mudanças, responda ao Claude.</div>
  $botao
  $alertasHtml
  $kitHtml
  $sugestoesHtml
  <div style='font-size:13px;font-weight:bold;letter-spacing:1px;color:$($cor.azul);margin:8px 0'>PRÉVIA DO TEXTO NO SITE</div>
  $(Corpo-Artigo '')
</div></body></html>
"@
Gravar "$pastaTrabalho\email.html" $emailHtml
Gravar "$pastaTrabalho\titulo.txt" $rascunho.titulo
Gravar "$pastaTrabalho\ramo.txt" "senso-comum/$dia-$($escolhido.slug)"

# Descrição da proposta no GitHub (é o que aparece no app para revisar)
$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("## $($rascunho.titulo)`n`n_$($rascunho.chamada)_`n")
if ($alertas.Count -gt 0) { [void]$md.AppendLine("### ⚠️ Confira antes de aprovar"); $alertas | ForEach-Object { [void]$md.AppendLine("- $_") }; [void]$md.AppendLine() }
foreach ($m in $rascunho.mitos) {
  [void]$md.AppendLine("### O que dizem: '$($m.frase)'`n$($m.resposta)`n")
  $m.dados | ForEach-Object { [void]$md.AppendLine("- $($_.dado) [$([int]$_.fonte + 1)]") }
  [void]$md.AppendLine()
}
[void]$md.AppendLine("**Quem decide: $($rascunho.quem_decide.nivel).** $($rascunho.quem_decide.explicacao)`n")
[void]$md.AppendLine("**E o seu voto?** $($rascunho.e_o_voto)`n")
[void]$md.AppendLine("**Limites:**"); $rascunho.ressalvas | ForEach-Object { [void]$md.AppendLine("- $_") }
[void]$md.AppendLine("`n**Fontes:**")
for ($i = 0; $i -lt $escolhido.fontes.Count; $i++) { [void]$md.AppendLine("$($i + 1). [$($escolhido.fontes[$i].titulo)]($($escolhido.fontes[$i].url)) — $($escolhido.fontes[$i].orgao)") }
[void]$md.AppendLine("`n---`n### Kit para explicar`n**Resumo:**")
$k.resumo | ForEach-Object { [void]$md.AppendLine("1. $_") }
[void]$md.AppendLine("`n**Troque o difícil pelo simples:**")
$k.palavras | ForEach-Object { [void]$md.AppendLine("- ~~$($_.dificil)~~ → **$($_.simples)**") }
[void]$md.AppendLine("`n**Jeitos de explicar:**")
$k.jeitos | ForEach-Object { [void]$md.AppendLine("- **$($_.estilo):** $($_.texto)") }
[void]$md.AppendLine("`n**O que NÃO dizer:**")
$k.nao_dizer | ForEach-Object { [void]$md.AppendLine("- $_") }
[void]$md.AppendLine("`n---`nPara publicar: **Merge pull request**. Para descartar: **Close pull request**.")
Gravar "$pastaTrabalho\proposta.md" $md.ToString()

if ($Simular) {
  Gravar "$pastaSite\email.html" $emailHtml.Replace('{{LINK_REVISAO}}', '#')
  Log "Simulação: rascunho em previa-senso\ (site não alterado)."
} else {
  Log "Rascunho gravado em docs\senso-comum\$arquivoPagina."
}
