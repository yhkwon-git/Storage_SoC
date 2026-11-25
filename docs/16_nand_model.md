# NAND model

Step 3-2 turns the NAND model of the testbenches into a device with behavior of its own:
- busy times drawn per operation, from program-and-verify loops and erase pulses;
- wear, which shortens programs, lengthens erases and raises the bit error rate, and ends a block past its endurance;
- raw bit errors on reads, at a rate, in exact counts per region, or as stuck bits, with a log of every bit flipped;
- factory bad blocks with their markers;
- the rules a program must keep, checked;
- what a reset leaves when it stops an operation.

The model is `dv/tb/nand_model.sv`, used by `tb_nand` and by `tb_soc` (one per channel). No RTL changes in this step: the controllers, their synthesis, timing and CDC results are those of step 3-1 ([15_nand_channel.md](15_nand_channel.md)). Model, testbenches, firmware and scripts are at commit `6b4fc0a`, and every result below was measured there.

## Defaults

With its default knobs the model behaves as in step 3-1: fixed busy times, no bit errors, no bad blocks. Only the program rules are new and on by default, and every test of step 3-1 keeps them except the random one, which programs pages in no order on purpose. Each earlier test therefore runs exactly as before, with the same clock counts; the new behavior is turned on by the tests below.

## Busy times

With `profile` 1 each operation draws its busy time, from the confirm command to ready. Wear is a block's P/E cycles over its endurance (3,000 by default); U{0..4} is a whole number drawn from 0 to 4 and u a real number from [0, 1).

| Operation | Busy time | Fresh block | At the rated endurance |
| --- | --- | --- | --- |
| Read | 4.6 µs + 0.2 µs × U{0..4} | 4.6 to 5.4 µs | the same |
| Program | 2 µs + 1.5 µs × loops; loops = 10 + U{0..4} − floor(3 × wear) | 10 to 14 loops: 17 to 23 µs | 7 to 11 loops: 12.5 to 18.5 µs |
| Erase | 25 µs × pulses; pulses = 2 + floor(3 × wear + 2u), at most 6 | 2 or 3 pulses: 50 or 75 µs | 5 or 6 pulses: 125 or 150 µs |
| Reset | 2 µs; 2, 4 or 10 µs when it stops a read, a program or an erase | | |

- **Loops and pulses** follow how flash programs and erases: a program applies pulses and verifies until every cell has reached its level (incremental step pulse programming), an erase applies pulses until the block verifies erased. Cells that have been cycled many times program faster and erase slower.
- **Scale.** The times are shorter than a real device's, which run to hundreds of microseconds for a program and milliseconds for an erase, so that simulations stay short; what the controller and firmware see is the same: a busy time that varies, and its longest value.
- With `profile` 0 the times are step 3-1's fixed tR (5 µs), tPROG (20 µs), tBERS (50 µs) and tRST (2 µs).

## Wear

- **P/E cycles.** Every erase the device runs adds a cycle to its block, also one that fails or is stopped; one refused under write protect does not. A test sets a block's count directly to start it worn.
- **Endurance.** An erase that would need more than 6 pulses fails after 6 (150 µs) and wears the block out: from then on its programs and erases fail (status bit 0). With the defaults no erase fails up to the rated endurance; past it the chance grows in a straight line, to certainty at 5/3 of it.
- **Bit error rate.** Each bit of a read flips with probability `rber` × (1 + 9 × wear): ten times the fresh rate at the rated endurance.

## Bit errors

Errors go into the page register when a read's tR ends, so a change of read column sees the same ones. The array itself never changes on a read.
- **Rate:** each bit of the 34,560 flips with the probability above. The gaps between errors are drawn from the geometric distribution, one draw per error, so a rate costs nothing when it is 0 and little when it is small.
- **Windows:** up to 8 regions of the page, each with an exact number of further bits to flip, all different. They are for testing an ECC decoder at and past its correction limit (step 3-3).
- **Stuck bits:** bits of a row that always read a given value, whatever the data. A bit stuck at the value it holds is no error.
- **The log.** `flip_log[row]` lists the bits of the last read of each row that differ from the array, as column × 8 + bit. The testbenches compare every byte read with the expected data with exactly those bits flipped, so errors are checked to the bit, not only counted.
- **Erased pages** take errors as programmed ones do.

## Factory bad blocks

`set_bad(block)` marks a factory bad block: the first spare byte (column 4,096) of its first and last page reads 00h, and a program or an erase of it fails. Firmware finds these blocks by reading the markers before it erases anything.

## Rules

While `rules` is 1, the model reports each violation as an error:
- the pages of a block programmed in order; programming the same page again is a partial program;
- at most 4 programs of a page between erases;
- no program or erase of a factory bad block;
- no program in a block whose erase was stopped, until the block is erased again.

## A reset during an operation

A reset (FFh) stops the operation in progress f of the way through its busy time:
- **Program:** each bit it was to clear is cleared with probability f.
- **Erase:** each 0 bit of the block is set with probability f, and the block takes no program until it is erased again.
- **Read:** no page is left in the page register to change the column of.

With `profile` 1 the reset then takes the time of what it stopped. The controller meets this after a busy timeout, when firmware sends RESET to a device that is still busy.

## Random numbers

Every random choice of the model comes from a splitmix64 generator, seeded for each draw from the knob `seed`, the model's name and what the draw is for:
- the operation's number, for busy times;
- the row and how many times it has been read, for bit errors;
- the reset's number, for a stopped operation.

The same sequence of commands to a device therefore gives the same times and the same errors, whatever else the testbench runs beside it, and the two channels of `tb_soc` differ. The generator is independent of the simulator's own random numbers, so a testbench's stimulus is the same with the new behavior on or off.

## Knobs

| Knob | Default | Meaning |
| --- | --- | --- |
| `profile` | 0 | 1: busy times drawn per operation, and erases that fail from wear |
| `endurance` | 3,000 | Rated P/E cycles |
| `pe[block]` | 0 | P/E cycles of a block |
| `rber`, `rber_wear` | 0, 9 | Bit error rate of a fresh block; its rise at the rated endurance |
| `win_n`, `win_start[]`, `win_len[]`, `win_cnt[]` | 0 | Windows of exact error counts |
| `add_stuck(row, bit, value)` | none | A stuck bit |
| `set_bad(block)` | none | A factory bad block |
| `rules` | 1 | Check the program rules |
| `seed` | 1 | Seed of the generator |
| `fail_prog`, `fail_erase`, `stuck_busy` | 0 | Step 3-1's knobs: the next programs or erases fail; R/B# stays busy until a reset |

The busy-time constants (loops, pulses, their steps and the reset times) are knobs too, with the defaults in the table above.

## Tests

### `tb_nand`

Five tests join the twelve of step 3-1. Each checks what the model does against this description, through the controller as firmware would use it:

| Test | What it covers |
| --- | --- |
| `busy` | 36 erases, 96 programs and 30 reads on a fresh block, one halfway through its endurance and one at it. Each draws loops and pulses in its block's range, takes the time the formula gives, and BUSY_TIME agrees; every value of each distribution is drawn at least once. Worn cells program 2 to 4 loops faster on average |
| `wear` | No erase fails up to the rated endurance, and P/E cycles count. Past 5/3 of it an erase fails after 6 pulses, and the block's programs and erases fail from then on. Between the two, erases continue until the first failure |
| `abort` | A program and an erase stopped by RESET after a busy timeout: the share of bits each changed against how far it went, status not ready while busy, each reset's time, the rule against programming the block, a read stopped the same way |
| `rules` | Each rule broken once and reported once; partial programs up to the limit not reported; a factory bad block's markers, its erase and program failing |
| `biterr` | A rate's count over 32 reads, erased pages included; two reads of a page flipping different bits, the same read count giving the same bits; a change of read column seeing the read's bits; windows of 0, 1, 9 and 24 bits; stuck bits; a worn block's rate; the generator's mean and variance over 4,000 page loads straight into the model |

- **BUSY_TIME.** At 20 ns, BUSY_TIME is exactly the operation's time in clocks less tWB less one clock: for every one of the 162 operations of `busy`. The check allows one clock either way.
- **Random runs.** The even seeds run with busy times drawn and 200 bit errors per million. The random command streams do not change, since the model does not use the simulator's random numbers.
- **Coverage.** 34 new covergroup bins, 66 in all: program loops, erase pulses and read times by value; each stopped operation, rule and kind of bit error; wear failures, worn-out blocks and the bad-block marker.

### Model mutation check

`make -C dv nand-model-mut` plants 21 bugs in the model, one at a time, and runs the device tests and a random run with busy times drawn and bit errors on each:

| Where | Mutants |
| --- | --- |
| Bit errors | no errors at any rate; the log missing a flipped bit; a window one bit short; stuck bits ignored; every read of a row flipping the same bits; no rise with wear |
| Busy times and wear | worn cells programming no faster; worn blocks erasing no slower; no failure past the endurance; a worn-out block taking programs; a factory bad block's erase succeeding; no bad-block marker; an erase not counted; read times fixed; a stopping reset taking the idle time |
| Stopped operations | a stopped program leaving the page unchanged; a stopped program complete; a stopped erase leaving the data; a stopped erase leaving the block ready for programs |
| Rules | pages out of order unreported; one partial program too many unreported |

### SoC: `nand_char`

`fw/tests/nand_char.c` is a NAND characterization routine of the kind firmware runs at bring-up. `tb_soc` gives it devices with busy times drawn, 200 bit errors per million bits, factory bad blocks 7 and 40 on NAND0 and 13 on NAND1, and block 3 of NAND0 at its rated endurance. The firmware:
- **scans for bad blocks** on both channels at once: the marker bytes of the first and last page of all 64 blocks. A block is bad when a marker byte has fewer than four 1 bits, so a raw bit error or two in an erased byte does not make a good block look bad;
- **measures busy times** on NAND0, from BUSY_TIME after each command: block 2 (fresh) and block 3 (worn) erased, four pages of each programmed with pseudo-random data and read back. The worn block must erase slower and program faster;
- **counts raw bit errors** in those eight reads against the data programmed. The worn block must have more, and the testbench checks the firmware's total against the bits the model flipped.

## Results

`make -C dv nand`, `make -C dv nand-mut`, `make -C dv nand-model-mut` and `make -C dv soc`, at `6b4fc0a`.

### `tb_nand`

- **All runs pass:** 17 directed tests and 10 random seeds, with the assertions bound and none fired; 66 of 66 covergroup bins. RTL coverage of `rtl/nand/` is as at `f67f5d6`: line 99 of 107, branch 93 of 98, expression 173 of 179; toggle 80.8%.
- **Busy times drawn in `busy`:** programs 12.5 to 23 µs, erases 50 to 150 µs, reads 4.6 to 5.4 µs. Programs took 12.44 loops on average on the fresh block and 9.31 on the one at its rated endurance.
- **Wear:** from 4,000 cycles (4/3 of the rated 3,000) the fourth erase failed, at 4,004 cycles.
- **Stopped operations:** a program stopped 0.399 of the way through had written 0.399 of its 0 bits; an erase stopped 0.222 of the way through had set 0.217 of the 0 bits of a page.
- **Bit errors:** 1,143 in 32 page reads at a rate of 10⁻³, against 1,105.9 expected; at 2 × 10⁻⁴, 36 in six reads of a fresh block and 423 of a block at its rated endurance, against 414.7 expected. 4,000 page loads at 2 × 10⁻⁴ gave 6.986 errors a page on average with a variance of 7.270, against 6.912 and 6.911 for the binomial.
- **Random runs:** the same 486,922 bytes programmed and 616,328 read under 2,244,656 interface checks as at `f67f5d6`. The five even seeds read 631 pages with 4,190 bits flipped, and every byte matched the expected data with the logged bits flipped.
- **Mutation checks:** the RTL's 18 of 18 still caught; the model's 21 of 21.

### SoC

- **`nand_char`** passes alone and with background traffic, in 582,628 and 585,886 clocks:

  | Measured by firmware | Block 2 (fresh) | Block 3 (3,000 cycles) |
  | --- | --- | --- |
  | Erase, `clk_nand` clocks of BUSY_TIME | 2,491 (50 µs: 2 pulses) | 7,491 (150 µs: 6 pulses) |
  | Program, 4 pages | 841 to 991 (17 to 20 µs) | 691 to 916 (14 to 18.5 µs) |
  | Read, 4 pages | 221 to 261 (4.6 to 5.4 µs) | 221 to 251 (4.6 to 5.2 µs) |
  | Raw bit errors in 4 pages | 20 | 254 |

  - The scan found blocks 7 and 40 on NAND0 and 13 on NAND1, and no others.
  - The firmware counted 274 raw bit errors, the 274 the model flipped in those pages.
- **Every earlier firmware run is unchanged.** The other 29 runs of `make -C dv soc` (each test alone and with background traffic, and `nvme_rand`) exit after the same number of clocks, with the same host traffic, as at `f67f5d6`, compared line by line; `nand` takes 390,182 clocks, and `nvme_rand` hits 81 of 81 bins.

## Found on the way

- **The random test programs pages in no order** and the same page many times without an erase, as it was written to stress the controller. The program rules reported 51 violations in its first run with them on. The random test now turns the rules off, and `rules` checks them.
- **A test's own bug:** the stopped read first released the device's held R/B# before sending RESET, so the read ended normally and nothing was stopped. The abort count caught it.

## Limits

- **One kind of cell,** one bit per cell with no page types; no read disturb, retention loss, program disturb or temperature, and errors uniform over the page, not tied to data.
- **Times scaled down** from a real device's, and failure only from wear, bad blocks or the knobs; a program never fails from wear before the block is worn out.
- **No cache, multi-plane or parameter-page operations**, as in step 3-1.
- **Bit errors are only checked against the expected data so far;** step 3-3 adds the BCH decoder that corrects them, and step 3-4 runs NVMe reads and writes through it.

## How to run

```bash
make -C dv nand                   # tb_nand: 17 directed tests, random seeds, 66 bins
make -C dv nand-mut               # [MUT] 18 of 18 mutants in the RTL caught
make -C dv nand-model-mut         # [MUT] 21 of 21 mutants in the model caught
make -C dv soc                    # every firmware test, nand_char included
```
