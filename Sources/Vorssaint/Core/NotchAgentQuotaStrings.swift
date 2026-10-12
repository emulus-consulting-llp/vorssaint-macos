// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

struct NotchAgentQuotaStrings {
    let geminiPool: String
    let agyPool: String
    let waiting: String
    let unavailable: String
    let cached: String

    init(language: AppLanguage) {
        let values: (String, String, String, String, String)
        switch language {
        case .enUS:
            values = ("Gemini allowance in Antigravity", "Claude/GPT allowance in Antigravity",
                      "Waiting for updated limits", "Limits unavailable", "Cached")
        case .ptBR:
            values = ("Cota Gemini no Antigravity", "Cota Claude/GPT no Antigravity",
                      "Aguardando limites atualizados", "Limites indisponíveis", "Em cache")
        case .tr:
            values = ("Antigravity içindeki Gemini kotası", "Antigravity içindeki Claude/GPT kotası",
                      "Güncel sınırlar bekleniyor", "Sınırlar alınamıyor", "Önbellek")
        case .ru:
            values = ("Лимит Gemini в Antigravity", "Лимит Claude/GPT в Antigravity",
                      "Ожидание обновления лимитов", "Лимиты недоступны", "Из кэша")
        case .es:
            values = ("Cuota de Gemini en Antigravity", "Cuota de Claude/GPT en Antigravity",
                      "Esperando límites actualizados", "Límites no disponibles", "En caché")
        case .sk:
            values = ("Kvóta Gemini v Antigravity", "Kvóta Claude/GPT v Antigravity",
                      "Čaká sa na aktualizované limity", "Limity nie sú dostupné", "Z vyrovnávacej pamäte")
        case .de:
            values = ("Gemini-Kontingent in Antigravity", "Claude/GPT-Kontingent in Antigravity",
                      "Warten auf aktualisierte Limits", "Limits nicht verfügbar", "Gespeichert")
        case .fr:
            values = ("Quota Gemini dans Antigravity", "Quota Claude/GPT dans Antigravity",
                      "En attente de limites actualisées", "Limites indisponibles", "En cache")
        case .it:
            values = ("Quota Gemini in Antigravity", "Quota Claude/GPT in Antigravity",
                      "In attesa di limiti aggiornati", "Limiti non disponibili", "In cache")
        case .ja:
            values = ("Antigravity内のGemini利用枠", "Antigravity内のClaude/GPT利用枠",
                      "利用枠の更新を待っています", "利用枠を取得できません", "キャッシュ")
        case .ko:
            values = ("Antigravity의 Gemini 사용 한도", "Antigravity의 Claude/GPT 사용 한도",
                      "업데이트된 한도 대기 중", "한도를 확인할 수 없음", "캐시")
        case .uk:
            values = ("Ліміт Gemini в Antigravity", "Ліміт Claude/GPT в Antigravity",
                      "Очікування оновлених лімітів", "Ліміти недоступні", "З кешу")
        case .zhHans:
            values = ("Antigravity 中的 Gemini 额度", "Antigravity 中的 Claude/GPT 额度",
                      "等待额度更新", "额度不可用", "缓存")
        case .zhTW:
            values = ("Antigravity 中的 Gemini 額度", "Antigravity 中的 Claude/GPT 額度",
                      "等待額度更新", "無法取得額度", "快取")
        case .zhHK:
            values = ("Antigravity 中的 Gemini 額度", "Antigravity 中的 Claude/GPT 額度",
                      "等待額度更新", "無法取得額度", "快取")
        }
        (geminiPool, agyPool, waiting, unavailable, cached) = values
    }
}
