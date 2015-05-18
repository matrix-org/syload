#! /usr/bin/python

from pylab import *
import csv
from simplescript import simplescript

@simplescript
def plot_loadtest(path, messages=False):
    data = list(l.split(" ") for l in open(path))
    h = data[0][1:]
    data = array(list(map(float, l) for l in data[1:]))
    x_i = 1 if messages else 0
    for y_i in range(3, len(h)):
        plot(data[:,x_i], data[:,y_i], label=h[y_i])
    legend()
    title(path)
    xlabel(["Time (s)", "Total Messages"][x_i])
    ylabel("Latency (s)")
    show()
