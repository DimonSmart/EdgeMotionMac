# Engineering Rules Index

This index is a compact discovery projection for current Engineering Rules. Full rule documents are normative.

The `Rule` column contains stable `ENG-NNNN` identifiers only. Resolve each ID to exactly one current `.idd/engineering/ENG-NNNN.rule-*.md` file.

Next ID: ENG-0004

| Rule | Applicability | Applies when | Summary |
| --- | --- | --- | --- |
| ENG-0001 | Conditional | Изменение input backend или cursor output | Private ABI изолирован bridge; публичный CGEvent output |
| ENG-0002 | Conditional | Изменение алгоритма Edge Motion и его границ | Детерминированный Swift engine независимо от macOS APIs |
| ENG-0003 | Conditional | Изменение доставки кадров, обработки ввода или scheduling | Callback-driven input без UI, I/O и блокирующей работы в callback |
