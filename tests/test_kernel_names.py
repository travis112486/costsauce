from api.kernel import normalize_name, match_ingredient


def test_normalize_ports_legacy_behavior():
    assert normalize_name("  Chicken  Breasts ") == "chicken breast"
    # punctuation strips FIRST, so this ends in 'd' and keeps no plural-s edit
    assert normalize_name("Tomatoes, Crushed!") == "tomatoes crushed"
    assert normalize_name("chkn brst") == "chkn brst"
    assert normalize_name("Swiss") == "swiss"          # 'ss' guard
    assert normalize_name("Gas") == "gas"              # len <= 3 guard
    assert normalize_name("Limes") == "lime"
    assert normalize_name("!!!") == ""


def test_match_exact_beats_fuzzy_and_first_wins():
    cands = [("id1", "Chicken Breast"), ("id2", "Chicken Breast Thin")]
    assert match_ingredient("chicken breasts", cands) == ("id1", "Chicken Breast", "exact")
    assert match_ingredient("breast", cands) == ("id1", "Chicken Breast", "fuzzy")


def test_match_empty_and_none():
    assert match_ingredient("!!!", [("id1", "Salt")]) is None
    assert match_ingredient("saffron", [("id1", "Salt")]) is None
