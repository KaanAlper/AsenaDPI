# AsenaDPI - eski tek-komut adresi; artik kok dizindeki install.ps1'e yonlendirir (ayni kurulum,
# ilerleme cubugu, SHA-256 dogrulama, guncelleme ve kaldirma ile). Bu adres calismaya devam eder:
#   irm https://raw.githubusercontent.com/KaanAlper/AsenaDPI/master/windows/get.ps1 | iex
# Yeni adres:
#   irm https://raw.githubusercontent.com/KaanAlper/AsenaDPI/master/install.ps1 | iex
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-RestMethod -UseBasicParsing https://raw.githubusercontent.com/KaanAlper/AsenaDPI/master/install.ps1 | Invoke-Expression
