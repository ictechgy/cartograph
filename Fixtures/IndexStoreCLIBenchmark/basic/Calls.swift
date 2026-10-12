func leaf(_ value: Int) -> Int { value + 1 } // oracle: leaf_int
func leaf(_ value: String) -> String { value } // oracle: leaf_string
func middle(_ value: Int) -> Int { leaf(value) } // oracle: middle
func disconnected() -> Int { 99 } // oracle: disconnected
