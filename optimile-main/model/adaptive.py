import random

class AdaptiveSelector:
    def __init__(self, operators):
        self.operators = operators
        self.weights = {op: 1.0 for op in operators}
        self.scores = {op: 0.0 for op in operators}

    def select(self):
        total = sum(self.weights.values())
        r = random.uniform(0, total)
        acc = 0
        for op, w in self.weights.items():
            acc += w
            if acc >= r:
                return op
        return random.choice(list(self.operators))

    def reward(self, op, improvement):
        if improvement < 0:
            self.scores[op] += 5
        elif improvement == 0:
            self.scores[op] += 1

    def update(self, decay=0.8):
        for op in self.weights:
            self.weights[op] = max(
                0.1,
                decay * self.weights[op] + (1 - decay) * self.scores[op],
            )
            self.scores[op] = 0
