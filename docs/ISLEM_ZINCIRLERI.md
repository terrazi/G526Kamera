# Sınav işlem zincirleri ve "olması gerekenler" listesi (Tur 6)

Neden yazıldı: daha önce bazı işler için prosedür kurulmadığı, işlem öngörülmediği görüldü. Bu belge sınavın başından sonuna her adımı **zincir** olarak
yazar (tetik → kodda işlem → kullanıcının duyduğu → hata dalı → test) ve zincirde boşluk arar. Her satırdaki `kod` ve `test` adlarını
`docs` denetim betiği (aşağıda "Doğrulama") depoda arar; olmayan ad belgeyi geçersiz kılar.

**Durum işaretleri:** ✔ kodda var ve testle sınandı · ➕ bu turda eklendi, CI testi var · ⚠ bilinçli sınır (nedeniyle yazılı) · ◻ cihazda doğrulanmadı
(yalnız sahte mikrofon/kulaklık/ağ ile sınandı).

## 1. Sınav prosedüründe olması gerekenler (kontrol listesi)

| # | Olması gereken | Durum |
|---|---|---|
| 1 | Başlamadan önce izin, çevrimdışı dikte, kulaklık, mikrofon, internet, Gemini anahtarı denetimi; sorun varsa söylenir ve oturum açılmaz | ✔ |
| 2 | Telefonun ses seviyesi denetimi (kulaklıktan cevap duyulmayabilir) | ➕ |
| 3 | Bellek, ısı, güç modu, boş yer denetimi ve uyarısı | ✔ |
| 4 | Soru numarasıyla okunur; numara yoksa sorulur ("sıradaki" ile otomatik) | ✔ |
| 5 | "Cevapla / Gönder" ile gönderim; metin yoksa "soru duyulmadı" denir | ✔ |
| 6 | Gemini cevabı kulaklıktan okunur, `soru_N` olarak kaydedilir, hata olursa söylenir | ✔ |
| 7 | Aynı numaralı soru yeniden cevaplanırsa eski cevabın ezildiği söylenir | ➕ |
| 8 | Ortak paragraf: okuma/çekme, hangi sorulara ait, her soruyla birlikte gider, bitince bırakılır | ✔ |
| 9 | Kamera ile soru çekme: kestirmeler, bağlanma, konumlandırma, çekim, internete dönüş, gönderim, yeniden deneme | ✔ ◻ |
| 10 | Yanlış okunan soruyu / paragrafı iptal etme | ✔ |
| 11 | Cevapları tekrar dinleme (hepsi, sonuncusu, N. soru) her bekleme durumunda | ✔ (N. soru: numara ve paragraf numarası beklerken ➕) |
| 12 | Anlamadığında program söyler; kullanıcı anlamadığında tekrar ister | ✔ |
| 13 | Her düzeltme/bilgi komutu yaptığını ya da yapamadığını söyler | ✔ |
| 14 | Hangi soruların cevapsız kaldığını sorma ve **test sonunda söyleme** | ✔ sorma · ➕ test sonu |
| 15 | Rapor: internet, mikrofon, kulaklık, ses, kamera/görüntü, şarj, ısınma, bellek, genel | ➕ |
| 16 | Ses seviyesini sesle ayarlama (aç, kıs, yüzde N) ve sonucu doğrulama | ➕ ◻ |
| 17 | Kamera ayarlarını sesle değiştirme (soru, kalite, video, süre, kadraj, yön, konumlandırma, iyileştirme, önizleme) | ➕ |
| 18 | Testi bitirme onayı, bitirmeden önce cevapları okuma ve menü, bitiş cümlesi | ✔ |
| 19 | Kulaklık / mikrofon / internet kopması: sustur, onar, söyle, kaldığı yerden sürdür | ✔ ◻ |
| 20 | Uygulama beklenmedik kapanırsa yeniden başlar, yarım işi tamamlar, söyler | ✔ ◻ |
| 21 | Hiçbir adımda sonsuz bekleme/döngü yok (gözcü, sınırlı hatırlatma) | ✔ |
| 22 | Cevapların okunması sırasında sesle araya girme | ⚠ yok (okuma sürerken dinleme açık değil); ekrandaki Duraklat düğmesi kullanılır |
| 23 | Paragraf okunurken komut söyleme | ⚠ yalnız söz tek başınaysa (paragraf serbest metindir) |
| 24 | Numara / paragraf numarası beklerken "testi bitir" | ⚠ yok (kısa numara cevabıyla karışır); önce soruyu cevaplayın ya da "soruyu iptal et" |

## 2. Zincirler

Kısaltma: Say.ad = konuşulan cümle (Sources/Models/Say.swift, SayReports.swift). Test sütununda dosya adı yok, test adı var (Tests/ altında aranır).

### Z1 Açılış

| Adım | Tetik | Kodda işlem (`kod`) | Kullanıcı duyar | Hata dalı | Test | Durum |
|---|---|---|---|---|---|---|
| Başlat | düğme / URL / otomasyon | `start`, `runStartup` | "Ben hazırım, sistem kontrol edildi ve problem yok." (`Say.readyCamera` kameralıysa) | izin, dikte, kulaklık, mikrofon, internet, anahtar yoksa `failStart` söyler ve oturum açılmaz | `testStartAnnouncesReadyThenListens`, `testMissingOnDeviceDictationStopsStart`, `testRejectedKeyStopsStartAndSaysSo` | ✔ |
| Ses seviyesi | açılışta ve dakikada bir | `applyVolume`, `checkSystemAtStart`, `systemTick` | düşükse `Say.lowVolume` (oturum engellenmez) | seviye okunamıyorsa uyarı yok | `testLowVolumeAtStartWarnsButDoesNotBlockTheSession`, `testLowVolumeWarningClearsWhenTheVolumeRises`, `testLowVolumeAppearsDuringTheSessionToo`, `testUnknownVolumeGivesNoWarning` | ➕ |
| Kaynak durumu | açılışta ve dakikada bir | `checkSystemAtStart`, `systemTick` | bellek/ısı/güç/boş yer uyarıları | yük hafifletilir, oturum sürer | `testLowMemoryAtStartLightensTheLoadBeforeListening`, `testThermalSeriousAndCriticalWarnAndClearWhenItCoolsDown` | ✔ |
| Önceki kayıt | klasörde cevap varsa | `runStartup` | "Önceki kayıtta N cevap var… devam mı, yeni mi?" | cevapsızlıkta bir hatırlatma, sonra 12 saat kuralı | `testRestartAfterEndTestAsksAndContinuingKeepsFolderAndNumbering`, `testUnansweredChoiceStartsNewWhenTheRecordIsOld` | ✔ |

### Z2 Tek soru

| Adım | Tetik | Kodda işlem | Kullanıcı duyar | Hata dalı | Test | Durum |
|---|---|---|---|---|---|---|
| Dinleme | oturum açık | `beginListening`, `reevaluateTrigger` | — (sessiz) | 30 sn sessizlikte dinleme yenilenir; mikrofon ölürse yeniden kurulur | `testSilenceWithLiveMicrophoneOnlyRestartsListening` | ✔ |
| Gönderim | "Cevapla / Gönder" | `fireQuestion` | "Soru gönderildi" (ayar açıksa) | yalnız "cevapla": `Say.noQuestionHeard`; metin var, tetikleyici yok: `questionIdle` | `testQuestionSentIsAnnouncedAfterCevapla`, `testBareTriggerWordSendsNothingAndTellsThatNoQuestionWasHeard` | ✔ |
| Numara | numara okunmadı | `fireNumber`, `numberUnclear`, `numberReply` | "Lütfen okuduğunuz sorunun numarasını söyleyin" | anlaşılmazsa yeniden sorulur, 2 hatırlatmadan sonra sıradaki numara | `testMissingNumberIsAskedAndWrittenAtTheStart`, `testSilenceRemindsTwiceThenSendsWithTheNextNumber` | ✔ |
| Cevap | Gemini yanıtı | `answer`, `store`, `speakNotice` | cevap okunur, `soru_N` kaydedilir | hata: `Say.geminiFailure`; kulaklık yoksa okunmaz, kayıt kalır | `testQuestionIsSentTrimmedAnsweredSpokenAndSaved`, `testGeminiFailureIsSpokenAndListeningResumes` | ✔ |
| Aynı numara yeniden | aynı numaralı yeni cevap | `answer` (`replacing`) | `Say.answerReplaced` | numara yanlış okunduysa kullanıcı fark eder | `testAnsweringTheSameNumberAgainSaysTheOldAnswerWasReplaced`, `testDifferentNumbersNeverSayReplaced` | ➕ |
| Sıradaki soru | cevap bitti | `beginListening` | "Lütfen sonraki soruyu okuyun" (ayar açıksa) | ayar kapalıysa sessiz | `testProgramAsksForTheNextQuestionItselfAfterTheAnswerIsHeard`, `testNextQuestionPromptCanBeTurnedOff` | ✔ |

### Z3 Ortak paragraf

| Adım | Tetik | Kodda işlem | Kullanıcı duyar | Hata dalı | Test | Durum |
|---|---|---|---|---|---|---|
| Başlatma | "Ortak paragraf" | `firePassagePrompt`, `firePassage` | "Lütfen ortak paragrafı okuyun, bitince Tamam deyin" | "tamam" cümle içindeyse kısa duraklamada bitmez; boş paragraf reddedilir | `testSayingOnlyOrtakParagrafAsksAloudToReadTheParagraphAndTamamFinishesIt`, `testEmptyPassageIsRejected` | ✔ |
| Numaralar | paragraf bitti | `fireTargets`, `finishTargets`, `targetsIdle`, `bestNumbers` | "Hangi sorular için? Numaraları söyleyip Tamam deyin" | "Tamam" yoksa program sorar; anlaşılmazsa 2 kez, sonra sıradaki soruya bağlanır | `testPassageTargetsAreClosedWithTamamAndNothingGoesToGemini`, `testPassageNumbersWithoutTamamAreConfirmedByTheProgram`, `testPassageTargetsUnclearThreeTimesFallBackToTheNextQuestion` | ✔ |
| Kullanım | numaralı soru | `answer` | — | hepsi cevaplanınca bırakılır | `testPassageIsSentWithItsQuestionsAndReleasedWhenAllAreAnswered` | ✔ |
| İptal | "Paragrafı iptal et" | `cancelPassage` | "Ortak paragraf iptal edildi" | yoksa "Silinecek ortak paragraf yok" | `testCancelPassageWhileReadingAbandonsIt`, `testCancelPassageWhileTheNumbersAreAskedDropsTheDraft` | ✔ |
| Cevap tekrarı numara beklerken | "N. sorunun cevabını tekrarla" | `run` (`.repeatNumber`), `reevaluateTrigger` | cevap, sonra `Say.reviewBackToTargets` | kayıt yoksa `Say.noAnswerFor`; paragraf taslağı korunur | `testRepeatNumberWhileThePassageNumbersAreAskedKeepsTheDraft` | ➕ |

### Z4 Komutlar, bilgi, rapor, ayar

| Adım | Tetik | Kodda işlem | Kullanıcı duyar | Hata dalı | Test | Durum |
|---|---|---|---|---|---|---|
| Çözümleme | tek başına söz | `VoiceCommand.parse`, `parseInfo`, `parseSetting` | — | olumsuz söz ("sesi kısma") ve sınav başlığı ("Bellek nedir") komut değildir | `testManyWaysOfAskingForEachReportAreUnderstood`, `testQuestionTitlesAndNegatedOrVagueWordsAreNotReportsOrSettings` | ➕ |
| Yürütme | komut sabit kaldı | `reevaluateTrigger`, `fireInfoCommand`, `performInfo`, `liveReply` | komutun sonucu (tek cümle) | kip, soru metni, tutulan soru bozulmaz; Gemini'ye gitmez | `testReportInTheMiddleOfAQuestionKeepsTheQuestionText`, `testReportsAndSettingsKeepTheConfirmationMode`, `testEveryCommandSaysWhatItDidOrThatItCouldNot` | ✔ ➕ |
| Rapor | "internet raporu", "şarj kaç"… | `reportText` | durumun kısa özeti | bilinmeyen bilgi söylenmez; internet raporu gerçekten yoklar | `testEachReportSpeaksTheCurrentStateAndGoesNowhere`, `testInternetReportProbesTheNetworkAndGemini`, `testGeneralReportCoversEveryPart`, `testCameraReportSpeaksTheSettings` | ➕ |
| Ses seviyesi | "sesi aç / kıs / yüzde N yap" | `changeVolume`, `VolumeControlling` | "Ses açıldı. Ses seviyesi yüzde N." | iOS izin vermezse "değiştirilemedi… ses tuşlarını kullanın"; en az yüzde 15 | `testVolumeUpDownAndSetAreAppliedAndVerified`, `testVolumeHasAFloorAndACeiling`, `testVolumeNotChangedByIOSIsSaidSo`, `testVolumeUnreadableIsSaidSo` | ➕ ◻ |
| Kamera ayarı | "görüntü kalitesini yüksek yap"… | `changeCameraSetting` | yapılan ayar söylenir | çekim sürerken reddedilir; yatay kadrajda dik çevirme reddedilir ve nedeni söylenir | `testCameraSettingsAreAppliedAndSpoken`, `testFrameAndOrientationFollowEachOther`, `testCameraSettingsAreRefusedWhileTheCameraWorks` | ➕ |
| Kamera sorusu | "kamera sorusunu kapat" | `changeCameraSetting`, `listenForVoiceQuestion` | "Kamera sorusu kapatıldı…" | kamera sorusu açıkken söylenirse evet/hayır beklenmez, soru sesle okunur | `testTurningTheCameraQuestionOffAtTheCameraQuestionLeavesIt`, `testOtherSettingsAtTheCameraQuestionKeepTheQuestionOpen` | ➕ |
| Cevap tekrarı | "N. sorunun cevabını tekrarla" | `run` | cevap; numara beklerken sonra `Say.reviewBackToNumber` | kayıt yoksa `Say.noAnswerFor` | `testRepeatNumberWhileTheQuestionNumberIsAskedReadsItAndAsksTheNumberAgain`, `testRepeatNumberWithoutAnAnswerSaysSoAndAsksTheNumberAgain`, `testAPlainNumberWhileTheNumberIsAskedStillAnswersTheQuestion` | ➕ |
| Anlaşılmayan | komut gibi ama tanınmadı | `commandNotUnderstood` | "Komutu anlayamadım…" | söz metinden atılır | `testUnrecognisedCommandAttemptIsAnnouncedAndDroppedFromTheText` | ✔ |
| Programı tekrarlatma | "anlamadım", "bir daha söyle" | `fireRepeatSpeech`, `repeatSpeech` | son söz yeniden | kip ve sayaçlar bozulmaz | `testManyWaysOfAskingForARepeatAreUnderstood` | ✔ |

### Z5 Test sonu

| Adım | Tetik | Kodda işlem | Kullanıcı duyar | Hata dalı | Test | Durum |
|---|---|---|---|---|---|---|
| Onay | "Testi bitir" | `run` (`.endTest`), `fireConfirmEnd` | "Testi bitirmek istiyor musunuz?" | anlaşılmazsa bir kez daha; cevapsızlıkta test sürer | `testEndCommandAsksForConfirmationAndYesEndsTheTest`, `testNoAnswerToTheConfirmationNeverEndsTheTest` | ✔ |
| Okuma ve menü | onaydan sonra | `beginReview`, `fireReview`, `resumeAfterReview` | cevaplar sırayla okunur, "Devam / Tekrar / Bitir" | okuma hatası bildirilir ve yine de menü sorulur | `testConfirmedEndReadsAllAnswersBackThenAsksWhatToDo`, `testAFailedPlaybackIsReportedAndStillAsksWhatToDo` | ✔ |
| Bitiş | "Bitir" | `completeTestByVoice`, `endTest` | "Test tamamlandı. N cevap kaydedildi." + cevapsız numaralar | boşluk yoksa cümle değişmez | `testTestCompletionTellsWhichQuestionsHaveNoAnswer`, `testTestCompletionWithoutGapsStaysAsBefore`, `testCompletionSentenceShortensALongList` | ➕ |

### Z6 Kesinti ve onarım

| Adım | Tetik | Kodda işlem | Kullanıcı duyar | Hata dalı | Test | Durum |
|---|---|---|---|---|---|---|
| Kulaklık / mikrofon | yol değişti, nabız | `runRecovery` | susulur, onarılınca söylenir | kestirmeler sırayla, sınırlı döngü | `testRouteLossMutesAndPausesEverything`, `testHardwareStaysLostRunsResetShortcutAndRecovers` | ✔ ◻ |
| İnternet | kopma | `runRecovery`, `waitForInternet`, `checkGemini` | "İnternet gitti… geri geldi" | başarısızsa duraklar, internet gelince sürer | `testNetworkLossRunsShortcutsInOrderThenAnnouncesRecovery`, `testFailedRecoveryPausesRetriesAndResumesWhenOnlineAgain` | ✔ ◻ |
| Anlık tespit | nabız | `systemTick` | — | iki kaçırılan nabız onarımı başlatır | `testTwoMissedBeatsStartTheRepairWithoutWaitingForAnyNotification`, `testStalledMicIsRebuiltWithinSecondsAndTheHalfSentenceIsKept` | ✔ ◻ |
| Beklenmedik kapanma | yeniden açılış | `runStartup` (defter) | "Program beklenmedik kapandı…" | döngüye girerse otomatik başlatma durur | `testUnexpectedCloseRestartsTheSessionAndSaysWhatHappened`, `testStartupLoopStopsAutoStart` | ✔ ◻ |

### Z7 Kamera ile soru

| Adım | Tetik | Kodda işlem | Kullanıcı duyar | Hata dalı | Test | Durum |
|---|---|---|---|---|---|---|
| Soru | her soru sınırı | `askCameraChoice`, `fireCameraChoice` | "Bu soruyu kamera ile çekip göndermek ister misiniz?" | anlaşılmazsa bir kez daha, sonra sesle okuma | `testStartAsksTheCameraQuestionAfterTheReadyAnnouncement`, `testCameraChoiceVocabularyDoesNotTreatCommandsAsYes` | ✔ |
| Hayır | "hayır" | `declineCamera` | `Say.cameraDeclined` | — | `testNoLetsTheUserReadTheQuestionAsInVersionThree` | ✔ |
| Evet | "evet" | `runCameraCapture`, `sendWithRetry`, `restoreInternetIfStrandedOnCamera` | aşama aşama bilgi, sonra cevap | çekim olmazsa söylenir, soru sesle; internet gelmezse çekim bekler | `testYesRunsShortcutsCaptureAndSendInTheRightOrderThenAsksAgain`, `testFailedCaptureReturnsToInternetThenFallsBackToTheVoiceFlow`, `testInternetNotBackKeepsTheShotRunsRecoveryThenSendsIt` | ✔ ◻ |
| Bekleyen çekim | internet geldi | `sendPendingShots` | "Önceki çekim gönderiliyor" | bir kez yeniden denenir, sonra atılır ve söylenir | `testAShotThatKeepsFailingIsRetriedOnceThenDroppedAndSaidSo` | ✔ |
| Paragraf (kamera) | "Ortak paragraf" | `firePassageCameraChoice` | "Paragrafı kamera ile çekmek ister misiniz?" | hayır: sesle okunur | `testPassageByCameraAsksWhichQuestionsThenKeepsTheImagesForThem`, `testDecliningTheCameraForThePassageReadsItAloudAsBefore` | ✔ ◻ |

## 3. Bulunan boşluklar ve çözümleri

1. **Telefonun ses seviyesi hiç denetlenmiyordu** (kulaklık bağlı ama ses sıfıra yakınsa cevaplar duyulmaz, program "okudum" der). Çözüm: `AVAudioSession.outputVolume`
   açılışta ve dakikada bir okunur; yüzde 10'un altında `Say.lowVolume` söylenir ve ekranda yazar. Seviye okunamıyorsa yanlış alarm verilmez.
2. **Aynı numaralı cevap sessizce eziliyordu** (numara yanlış okunduysa önceki cevap yok oluyordu). Çözüm: ezilince `Say.answerReplaced` söylenir.
3. **Test bitince cevapsız sorular söylenmiyordu** (yalnız istenince söylenirdi). Çözüm: bitiş cümlesi cevapsız numaraları da sayar.
4. **Numara / paragraf numarası beklerken "N. sorunun cevabını tekrarla" desteklenmiyordu** (kısa numara cevabı sanılıp "numarayı anlayamadım" denirdi).
   Çözüm: cevap okunur, ardından aynı soru yeniden sorulur; tutulan soru ve paragraf taslağı korunur.
5. **Tur 6 isteği:** raporlar (internet, mikrofon, kulaklık, ses, kamera/görüntü, şarj, ısınma, bellek, genel), ses seviyesi komutları ve kamera ayarı komutları.

## 4. Doğrulama

- **CI'da sınanan:** komut çözümleme (yüzlerce söyleyiş ve olumsuz örnek), her komutun söylediği cümle, kip/soru metni korunması, ayarların gerçekten değişmesi,
  bekleme durumlarında komutlar, boşluk 1–4 akışları. Sözlük ayrıca Python taklidiyle depodaki bütün test metinlerine karşı çakışma taramasından geçirildi.
- **Cihazda doğrulanmadı ◻:** gerçek dikte çıktısının biçimi, "sesi aç"ın iOS'ta gizli ses çubuğuyla gerçekten ses değiştirmesi (değişmezse program "değiştirilemedi" der; sonuç ses seviyesi
  yeniden okunarak doğrulanır), kestirmelerin etkisi, mikrofon davranışı, kamera bağlantısı.

## 5. Doğrulama betiği

Belgedeki her ``kod`` ve ``test`` adı depoda aranır:

```
python3 -I docs/check_chains.py
```
