# Time-phased_Supply_Allocation_Operation_Model
Available to Promise | Available to Sell

Try view it in Edit mode.

# Business scenario (background):
Mill_A supplies two products: A1 and A2
Mill_A produces as followed: unit of measure - EA
Week_1: A1 by 10 (EA); A2 by 20 (EA)
Week_2: A1 by 30 (EA); A2 by 10 (EA)
Week_3: A1 by 35 (EA); A2 by 15 (EA)
Mill_B supplies two products: B1 and B2
Mill_B produces as followed: unit of measure - EA
Week_1: B1 by 20 (EA); B2 by 10 (EA)
Week_2: B1 by 30 (EA); B2 by 15 (EA)
Week_3: B1 by 25 (EA); B2 by 20 (EA)
Shop_A demands two products: A1 and A2
Shop_A consumes as followed: unit of measure - EA
Week_1: A1 by 5 (EA); A2 by 15 (EA)
Week_2: A1 by 25 (EA); A2 by 12 (EA)
Week_3: A1 by 15 (EA); A2 by 17 (EA)
Shop_B demands two products: B1 and B2
Shop_B consumes as followed: unit of measure - EA
Week_1: B1 by 15 (EA); B2 by 8 (EA)
Week_2: B1 by 32 (EA); B2 by 17 (EA)
Week_3: B1 by 32 (EA); B2 by 10 (EA)

NOTE:
Each Mill will publish its production forecast monthly (by products).
Each Mill will re-publish its production forecast weekly (by products) with updates.
Each Shop will consume the forecasted supply (produced by Mills and products) accordingly (based upon the latest the published supply forecast).

A general manager of all these Mills and Shops want to achieve:
Create a business operation model: Supply (what Mills could produce) drives Demand (what Shops could consume) and make sure both Supply and Demand balances at all time (by each production forecast period, such as weekly or monthly). That means Shops would never or rarely over-consume supply available.
Shops can always see what are available supply for consumption (by products and quantities) at all time.

Now you are an IT solution architect. How/what would you design and implement an effective solution assisting this general manager to achieve this business goal?
First let's discuss how well do you understand in this business scenario? what are the key elements to be considered or addressed during the design brainstorm exercise?

Start with precise records and lifecycle rules, then show how those definitions drive availability and exceptions.

Business decisions: Mill-specific supply, Shop-selected source, no cross-Mill splitting, and week-specific reservations that expire.

I’ll start with precise records and lifecycle rules, then show how those definitions drive availability and exceptions. This incorporates your decisions: Mill-specific supply, Shop-selected source, no cross-Mill splitting, and week-specific reservations that expire.

**1. Data records**

- **Forecast publication**: an immutable version containing a Mill’s forecast quantities by product and week. A correction creates a new version; only one version is active at a time.
- **Actual production**: reported quantity by Mill, product, and production week, stored separately from forecast. Corrections are recorded as auditable changes.
- **Demand request**: the Shop’s continuing need for a product and total quantity, assigned to one selected Mill. The Mill cannot change implicitly. The request may be fulfilled over multiple weeks, but only by that Mill.
- **Scheduled commitment**: a reservation against one demand request, Mill, product, and target week. It reserves forecast-backed availability for that week only.
- **Actual usage**: quantity actually consumed by the Shop in a week, linked to its request and, when applicable, its commitment. Actual usage is recorded even if it creates a deficit.
- **Reservation expiry**: an auditable event at week close for any remaining unconsumed reserved quantity. Expired units are no longer reserved, but the underlying need returns to pending status.
- **Balance**: a calculated, signed position for each Mill × product × week. Positive means projected supply remaining; negative means a carried deficit, not physical negative inventory.

All quantities should use a canonical product unit. A commitment should also retain its published forecast version reference for audit. The Shop’s selected Mill must be eligible to serve its location when the request is created.

**2. Demand and reservation lifecycle**

For a demand request:

$$
\text{Pending quantity}
=
\text{Requested quantity}
-
\text{Actual fulfilled quantity}
-
\text{Active reserved quantity}
-
\text{Cancelled demand quantity}
$$

A request can have commitments for different weeks, but all those commitments stay with its selected Mill. Rebooking an expired quantity creates a new commitment for a later week; it does not revive or extend the old reservation. The new commitment must pass the availability check for its target week.

At week close, the remaining quantity on a commitment expires and is released from that week’s projected balance. It raises the agreed red audit flag. Actualized quantity remains actual usage; it is not expired or released.

**3. Time-phased balance and availability**

For each Mill and product, process weeks chronologically. For an open or future week, use the latest published forecast. For a completed week, use reported actual production.

$$
\text{Projected ending balance}_t
=
\text{Projected opening balance}_t
+
\text{Supply}_t
-
\text{Actual usage}_t
-
\text{Active reserved quantity}_t
$$

The ending position becomes the next week’s opening position. A negative balance carries forward; later production first offsets the deficit before providing new availability. At week close, expired commitments are excluded from the realized balance:

$$
\text{Realized ending balance}_t
=
\text{Realized opening balance}_t
+
\text{Actual production}_t
-
\text{Actual usage}_t
$$

A new commitment is allowed only when the selected Mill’s time-phased projected availability covers it. The check includes earlier weeks’ carryover or deficit, usage, and active commitments. It cannot use another Mill’s supply or supply forecast for a later week.

Shops should see, separately, **usable realized carryover**, **available to reserve by future week**, **active commitments**, **pending demand**, and any **deficit**. That avoids presenting forecasted supply as physical supply already on hand.

**4. Transactions and exceptions**

- **Reserve**: atomically verify availability against the active forecast version and record the commitment. Concurrent reservations cannot claim the same units; retries must not create duplicates.
- **Publish forecast**: keep the current version active while the new version is prepared. Switch versions atomically. Shop operations continue during preparation and publication; transactions resolve against a consistent old or new version. Recalculate projections after the switch.
- **Forecast reduction**: preserve existing commitments and actual usage. If the new forecast makes availability negative, flag affected Mill/product/weeks; do not silently cancel reservations. New reservations against the active version still require sufficient availability.
- **Actual production shortfall or excess usage**: recalculate realized balances and downstream projections. A deficit carries forward and is visible. Actual usage is recorded even when it increases the deficit.
- **Expiry**: release unconsumed reserved quantity at week close, flag the expiry for audit, and leave the unmet request pending for possible rebooking.
- **Corrections**: retain prior forecast and actual values, who changed them, when, and the resulting recalculated balances.

This gives us a consistent first-pass specification. The next useful pass is to test it against concrete cases: a request partly reserved across weeks, a forecast decrease after reservations exist, a week with negative carryover, and an expiry followed by rebooking.
Corrections: retain prior forecast and actual values, who changed them, when, and the resulting recalculated balances.
This gives us a consistent first-pass specification. The next useful pass is to test it against concrete cases: a request partly reserved across weeks, a forecast decrease after reservations exist, a week with negative carryover, and an expiry followed by rebooking.
