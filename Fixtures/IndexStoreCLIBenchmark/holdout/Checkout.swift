func total(_ quantity: Int) -> Int { // oracle: total
    let amount = subtotal(quantity)
    return amount + tax(amount)
}
func receipt(_ quantity: Int) -> Int { total(quantity) } // oracle: receipt
func preview(_ quantity: Int) -> Int { subtotal(quantity) } // oracle: preview
func unusedQuote(_ quantity: Int) -> Int { quantity } // oracle: unused_quote
